#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::PAFCluster

=cut

=head1 SYNOPSIS

my $aa = $sdba->get_AnalysisAdaptor;
my $analysis = $aa->fetch_by_logic_name('PAFCluster');
my $rdb = new Bio::EnsEMBL::Compara::RunnableDB::PAFCluster(
                         -input_id   => "{'species_set'=>[1,2,3,14]}",
                         -analysis   => $analysis);

$rdb->fetch_input
$rdb->run;

=cut

=head1 DESCRIPTION

This is a compara specific runnableDB, that based on an input_id
of arrayrefs of genome_db_ids, and from this species set relationship
it will search through the peptide_align_feature data and build 
SingleLinkage Clusters and store them into a NestedSet datastructure.  
This is the first step in the ProteinTree analysis production system.

=cut

=head1 CONTACT

  Contact Jessica Severin on module implemetation/design detail: jessica@ebi.ac.uk
  Contact Abel Ureta-Vidal on EnsEMBL/Compara: abel@ebi.ac.uk
  Contact Ewan Birney on EnsEMBL in general: birney@sanger.ac.uk

=cut

=head1 APPENDIX

The rest of the documentation details each of the object methods. 
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Compara::RunnableDB::PAFCluster;

use strict;
use Switch;
use Bio::EnsEMBL::Compara::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Hive;
use Bio::EnsEMBL::Compara::NestedSet;
use Bio::EnsEMBL::Compara::Homology;
use Time::HiRes qw(time gettimeofday tv_interval);

our @ISA = qw(Bio::EnsEMBL::Hive::Process);

sub fetch_input {
  my( $self) = @_;

  $self->{'species_set'} = undef;
  $self->throw("No input_id") unless defined($self->input_id);

  #create a Compara::DBAdaptor which shares the same DBI handle
  #with the Pipeline::DBAdaptor that is based into this runnable
  $self->{'comparaDBA'} = Bio::EnsEMBL::Compara::DBSQL::DBAdaptor->new(-DBCONN=>$self->db->dbc);
  $self->{'selfhit_score_hash'} = {};
  $self->{'no_filters'} = 0;
  $self->{'all_bests'} = 0;
  $self->{'include_brh'} = 1;
  $self->{'bsr_threshold'} = 0.25;
  
  $self->get_params($self->input_id);
  return 1;
}

sub get_params {
  my $self         = shift;
  my $param_string = shift;

  return unless($param_string);
  print("parsing parameter string : ",$param_string,"\n");
  
  my $params = eval($param_string);
  return unless($params);

  foreach my $key (keys %$params) {
    print("  $key : ", $params->{$key}, "\n");
  }

  if (defined $params->{'species_set'}) {
    $self->{'species_set'} = $params->{'species_set'};
  }
  if (defined $params->{'gene_stable_id'}) {
    $self->{'gene_stable_id'} = $params->{'gene_stable_id'};
  }
  if (defined $params->{'all_bests'}) {
    $self->{'all_bests'} = $params->{'all_bests'};
  }
  if (defined $params->{'no_filters'}) {
    $self->{'no_filters'} = $params->{'no_filters'};
  }
  if (defined $params->{'bsr_threshold'}) {
    $self->{'bsr_threshold'} = $params->{'bsr_threshold'};
  }
  if (defined $params->{'brh'}) {
    $self->{'include_brh'} = $params->{'brh'};
  }
  
  print("parameters...\n");
  printf("  species_set    : (%s)\n", join(',', @{$self->{'species_set'}}));
  printf("  BRH            : %d\n", $self->{'include_brh'});
  printf("  all_blast_hits : %d\n", $self->{'no_filters'});
  printf("  all_bests      : %d\n", $self->{'all_bests'});  
  printf("  bsr_threshold  : %1.3f\n", $self->{'bsr_threshold'});  
  
  return;
}

sub run
{
  my $self = shift;  
  return 1;
}

sub write_output {
  my $self = shift;
  
  $self->build_paf_clusters();
  
  return 1;
}

##########################################
#
# internal methods
#
##########################################

sub build_paf_clusters {
  my $self = shift;
  
  my $build_mode = 'direct';
  
  return unless($self->{'species_set'});
  my @species_set = @{$self->{'species_set'}};
  return unless @species_set;

  my $mlssDBA = $self->{'comparaDBA'}->get_MethodLinkSpeciesSetAdaptor;
  my $pafDBA = $self->{'comparaDBA'}->get_PeptideAlignFeatureAdaptor;
  my $treeDBA = $self->{'comparaDBA'}->get_ProteinTreeAdaptor;
  my $starttime = time();
   
  $self->{'tree_root'} = new Bio::EnsEMBL::Compara::NestedSet;
  $self->{'tree_root'}->name("ORTHO_CLUSTERS");
  $treeDBA->store($self->{'tree_root'});
  printf("root_id %d\n", $self->{'tree_root'}->node_id);
    
  #
  # create Cluster MLSS
  #
  $self->{'cluster_mlss'} = new Bio::EnsEMBL::Compara::MethodLinkSpeciesSet;
  $self->{'cluster_mlss'}->method_link_type('ORTHO_CLUSTERS'); 
  my @genomeDB_set;
  foreach my $gdb_id (@species_set) {
    my $gdb = $self->{'comparaDBA'}->get_GenomeDBAdaptor->fetch_by_dbID($gdb_id);
    push @genomeDB_set, $gdb;
  }
  $self->{'cluster_mlss'}->species_set(\@genomeDB_set);
  $mlssDBA->store($self->{'cluster_mlss'});
  printf("MLSS %d\n", $self->{'cluster_mlss'}->dbID);
  
  $self->{'member_leaves'} = {};
  
  eval {
  #  
  # load all the self equal hits for each genome so we have our reference score
  #
  
  $self->fetch_selfhit_score;

  #  
  # for each species pair, get all 'high scoring' hits and build clusters
  # 
  
  while (my $gdb_id1 = shift @species_set) {
    #first get paralogues
    $self->threshold_grow_for_species($gdb_id1);
    
    foreach my $gdb_id2 (@species_set) {
      $starttime = time();
      $self->BRH_grow_for_species($gdb_id1, $gdb_id2);
      $self->threshold_grow_for_species($gdb_id1, $gdb_id2);
    }
  }
  
  $self->store_clusters;
  
  $self->dataflow_clusters;
  
  }; #eval
  
  
  $self->{'tree_root'}->release;
  $self->{'tree_root'} = undef;
}


#########################################################################
#
# new fast algorithm idea:
#  1) use light weight query to get 'homologies' as a peptide_pair
#     array reference of two member_ids
#  2) use NestedSet/AlignedMember objects in light-weight mode
#     by only storing member_ids
#  3) build clusters in memory (uses very little now)
#  4) store
#
#########################################################################


sub fetch_selfhit_score {
  my $self= shift;
  
  my $starttime = time();

  my $sql = "SELECT qmember_id, score ".
            "FROM peptide_align_feature paf ".
            "WHERE qmember_id=hmember_id ". 
            "AND qgenome_db_id IN (". join(',', @{$self->{'species_set'}}). ")";
  print("$sql\n");
  my $sth = $self->dbc->prepare($sql);
  $sth->execute();
  print("  done with fetch\n");
  while( my $ref  = $sth->fetchrow_arrayref() ) {
    my ($member_id, $score) = @$ref;
    $self->{'selfhit_score_hash'}->{$member_id} = $score;
  }
  $sth->finish;
  printf("%1.3f secs to process\n", (time()-$starttime));
}


sub BRH_grow_for_species
{
  my $self = shift;
  my ($gdb1, $gdb2) = @_;
  
  return unless($self->{'include_brh'});
  
  my $starttime = time();
  
  my $sql = "SELECT paf1.qmember_id, paf1.hmember_id, paf1.score, paf1.hit_rank ".
            "FROM peptide_align_feature paf1 ".
            "JOIN peptide_align_feature paf2 ".
            "  ON( paf1.qmember_id = paf2.hmember_id and paf1.hmember_id = paf2.qmember_id)  ".
            "WHERE paf1.qgenome_db_id = $gdb1 AND paf1.hgenome_db_id = $gdb2 ".
            "AND   paf2.qgenome_db_id = $gdb2 AND paf2.hgenome_db_id = $gdb1 ".
            "AND paf1.hit_rank=1 and paf2.hit_rank =1";

  print("$sql\n");
  my $sth = $self->dbc->prepare($sql);
  $sth->execute();
  printf("  %1.3f secs to fetch BRHs via PAF\n", (time()-$starttime));

  my $midtime = time();
  my $paf_counter=0;
  while( my $ref  = $sth->fetchrow_arrayref() ) {
    my ($pep1_id, $pep2_id, $score, $hit_rank) = @$ref;
    $paf_counter++;

    my $pep_pair = [$pep1_id, $pep2_id];
    $self->grow_memclusters_with_peppair($pep_pair);
  }
  
  printf("  %d clusters so far\n", $self->{'tree_root'}->get_child_count);  
  printf("  %d members in hash\n", scalar(keys(%{$self->{'member_leaves'}})));
  printf("  %1.3f secs to process %d BRH PAFs\n", time()-$midtime, $paf_counter);
  printf("  %1.3f secs to load/process\n", (time()-$starttime));
}



sub threshold_grow_for_species
{
  my $self = shift;
  my @species_set = @_;
  
  my $starttime = time();
  my $species_string = "(" . join(',', @species_set) . ")";
  
  my $sql = "SELECT paf.qmember_id, paf.hmember_id, paf.score, paf.hit_rank ".
            "FROM peptide_align_feature paf ".
            "WHERE paf.qmember_id != paf.hmember_id ".
            "AND paf.qgenome_db_id in $species_string ".
            "AND paf.hgenome_db_id in $species_string ";
  if(scalar(@species_set) > 1) { 
    $sql .= "AND paf.qgenome_db_id != paf.hgenome_db_id ";
  }

  print("$sql\n");
  my $sth = $self->dbc->prepare($sql);
  $sth->execute();
  printf("  %1.3f secs to fetch PAFs\n", (time()-$starttime));

  my $midtime = time();
  my $paf_counter=0;
  my $included_pair_count=0;
  my $included_bests_count=0;
  while( my $ref  = $sth->fetchrow_arrayref() ) {
    my ($pep1_id, $pep2_id, $score, $hit_rank) = @$ref;

    $paf_counter++;

    my $include_pair = 0;
    if($self->{'no_filters'}) {
      $include_pair = 1;
    } 
    
    if(!$include_pair and $self->{'all_bests'} and $hit_rank==1) {
      $included_bests_count++;
      $include_pair = 1;
    } 
    
    if(!$include_pair) {
      unless(defined($self->{'selfhit_score_hash'}->{$pep1_id})) {
        printf("member_pep %d missing self_hit\n", $pep1_id);
      }
      unless(defined($self->{'selfhit_score_hash'}->{$pep2_id})) {
        printf("member_pep %d missing self_hit\n", $pep2_id);
      }

      #find largest self hit blast score to use as reference
      my $ref_score = $self->{'selfhit_score_hash'}->{$pep1_id};
      my $ref2_score = $self->{'selfhit_score_hash'}->{$pep2_id};
      if(!defined($ref_score) or 
         (defined($ref2_score) and ($ref2_score > $ref_score))) 
      {
        $ref_score = $ref2_score;
      }
      
      #do blast score ratio (BSR) filter (
      if(defined($ref_score) and ($score / $ref_score > $self->{'bsr_threshold'})) {
        $include_pair=1;
      }
    }
    
    if($include_pair) {
      $included_pair_count++;
      my $pep_pair = [$pep1_id, $pep2_id];
      $self->grow_memclusters_with_peppair($pep_pair);
    }
  }
  
  printf("  %d clusters so far\n", $self->{'tree_root'}->get_child_count);  
  printf("  %d members in hash\n", scalar(keys(%{$self->{'member_leaves'}})));
  printf("  %1.3f secs to process %d PAFs => %d picked (%d best + %d threshold)\n", 
         time()-$midtime, $paf_counter, $included_pair_count, $included_bests_count, 
         $included_pair_count- $included_bests_count);
  printf("  %1.3f secs to load/process\n", (time()-$starttime));
}


=head2 grow_memclusters_with_peppair

  Description: Takes a pair of peptide_member_id and uses the NestedSet objects
     to build a 3 layer tree in memory.  There is a single root for the entire build
     process, and each cluster is a child of this root.  The members are children of
     the clusters. During the build process the member leaves are assigned a node_id
     equal to the peptide_member_id so they can be found via 'find_node_by_node_id'.
     After the process is completed, each cluster can then be stored in a faster 
     bulk insert process.
    
=cut


sub grow_memclusters_with_peppair {
  my $self = shift;
  my $pep_pair = shift;
  my ($pep1_id, $pep2_id) = @{$pep_pair};
   
  #printf("homology peptide pair : %d - %d\n", $pep1_id, $pep2_id); 
  my $mlss_id = $self->{'cluster_mlss'}->dbID;
  
  my ($treeMember1, $treeMember2);
  $treeMember1 = $self->{'member_leaves'}->{$pep1_id};
  $treeMember2 = $self->{'member_leaves'}->{$pep2_id};

  if(!defined($treeMember1)) {
    $treeMember1 = new Bio::EnsEMBL::Compara::AlignedMember;
    $treeMember1->method_link_species_set_id($mlss_id);
    $treeMember1->member_id($pep1_id);
    $treeMember1->node_id($pep1_id);
    $self->{'member_leaves'}->{$pep1_id} = $treeMember1;
  }
  if(!defined($treeMember2)) {
    $treeMember2 = new Bio::EnsEMBL::Compara::AlignedMember;
    $treeMember2->method_link_species_set_id($mlss_id);
    $treeMember2->member_id($pep2_id);
    $treeMember2->node_id($pep2_id);
    $self->{'member_leaves'}->{$pep2_id} = $treeMember2;
  }
  
  my $parent1 = $treeMember1->parent;
  my $parent2 = $treeMember2->parent;
        
  if(!defined($parent1) and !defined($parent2)) {
    #neither member is in a cluster so create new cluster with just these 2 members
    # printf("create new cluster\n");
    my $cluster = new Bio::EnsEMBL::Compara::NestedSet;
    $self->{'tree_root'}->add_child($cluster);
    $cluster->add_child($treeMember1);
    $cluster->add_child($treeMember2);
  }
  elsif(defined($parent1) and !defined($parent2)) {
    # printf("add member to cluster %d\n", $parent1->node_id);
    # $treeMember2->print_member; 
    $parent1->add_child($treeMember2);
  }
  elsif(!defined($parent1) and defined($parent2)) {
    # printf("add member to cluster %d\n", $parent2->node_id);
    # $treeMember1->print_member; 
    $parent2->add_child($treeMember1);
  }
  elsif(defined($parent1) and defined($parent2)) {
    if($parent1->equals($parent2)) {
      # printf("both members already in same cluster %d\n", $parent1->node_id);
    } else {
      #this member already belongs to a different cluster -> need to merge clusters
      # print("MERGE clusters\n");
      $parent1->merge_children($parent2);
      $parent2->disavow_parent; #releases from root
    }
  }

}


sub fetch_max_leftright_index {
  my $self= shift;

  my $sql = "SELECT max(right_index) FROM protein_tree_nodes;";
  my $sth = $self->dbc->prepare($sql);
  $sth->execute();
  my ($max_counter) = $sth->fetchrow_array();
  $sth->finish;
  return $max_counter + 1;
}


sub store_clusters {
  my $self = shift;
  
  my $starttime = time();

  my $treeDBA = $self->{'comparaDBA'}->get_ProteinTreeAdaptor;

  printf("storing the clusters\n");
  my $leaves = $self->{'tree_root'}->get_all_leaves;
  printf("    loaded %d leaves\n", scalar(@$leaves));
  my $count=0;
  foreach my $mem (@$leaves) { $count++ if($mem->isa('Bio::EnsEMBL::Compara::AlignedMember'));}
  printf("    loaded %d leaves which are members\n", $count);
  printf("    loaded %d members in hash\n", scalar(keys(%{$self->{'member_leaves'}})));
  printf("    %d clusters generated\n", $self->{'tree_root'}->get_child_count);  
  
  #printf("  building the leftright_index\n");
  #$self->{'tree_root'}->build_leftright_indexing(fetch_max_leftright_index($self));
  #printf("  store\n");
  
  my $clusters = $self->{'tree_root'}->children;
  my $counter=1; 
  foreach my $cluster (@{$clusters}) {    
    $treeDBA->store($cluster);
    if($counter++ % 200 == 0) { printf("%10d clusters stored\n", $counter); }
  }
  printf("  %1.3f secs to store clusters\n", (time()-$starttime));
  printf("tree_root : %d\n", $self->{'tree_root'}->node_id);
}


sub dataflow_clusters {
  my $self = shift;
  
  my $clusters = $self->{'tree_root'}->children;
  foreach my $cluster (@{$clusters}) {
    my $output_id = sprintf("{'protein_tree_id'=>%d}", $cluster->node_id);
    $self->dataflow_output_id($output_id, 2);
  }
}


1;
