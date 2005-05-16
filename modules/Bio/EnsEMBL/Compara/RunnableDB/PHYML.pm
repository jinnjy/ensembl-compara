#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::PHYML

=cut

=head1 SYNOPSIS

my $db      = Bio::EnsEMBL::Compara::DBAdaptor->new($locator);
my $repmask = Bio::EnsEMBL::Compara::RunnableDB::PHYML->new ( 
                                                    -db      => $db,
                                                    -input_id   => $input_id
                                                    -analysis   => $analysis );
$repmask->fetch_input(); #reads from DB
$repmask->run();
$repmask->output();
$repmask->write_output(); #writes to DB

=cut

=head1 DESCRIPTION

This Analysis/RunnableDB is designed to take ProteinTree as input
This must already have a multiple alignment run on it.  It uses that alignment
as input into the PHYML program which then generates a phylogenetic tree

input_id/parameters format eg: "{'protein_tree_id'=>1234}"
    protein_tree_id : use 'id' to fetch a cluster from the ProteinTree

=cut

=head1 CONTACT

Describe contact details here

=cut

=head1 APPENDIX

The rest of the documentation details each of the object methods. 
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Compara::RunnableDB::PHYML;

use strict;
use Getopt::Long;
use IO::File;
use File::Basename;
use Time::HiRes qw(time gettimeofday tv_interval);

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Compara::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Compara::Member;

use Bio::SimpleAlign;
use Bio::AlignIO;

use Bio::EnsEMBL::Hive;
our @ISA = qw(Bio::EnsEMBL::Hive::Process);

=head2 fetch_input

    Title   :   fetch_input
    Usage   :   $self->fetch_input
    Function:   Fetches input data for repeatmasker from the database
    Returns :   none
    Args    :   none
    
=cut

sub fetch_input {
  my( $self) = @_;

  $self->{'substitution_model'}                      = 'WAG';
  $self->{'transition_transversion_ratio'}           = 0.0;
  $self->{'number_of_substitution_rate_categories'}  = 4;
  $self->{'gamma_distribution_parameter'}            = 1;

  $self->throw("No input_id") unless defined($self->input_id);

  #create a Compara::DBAdaptor which shares the same DBI handle
  #with the Pipeline::DBAdaptor that is based into this runnable
  $self->{'comparaDBA'} = Bio::EnsEMBL::Compara::DBSQL::DBAdaptor->new(-DBCONN=>$self->db->dbc);

  $self->get_params($self->parameters);
  $self->get_params($self->input_id);
  $self->print_params if($self->debug);

  unless($self->{'protein_tree'}) {
    throw("undefined ProteinTree as input\n");
  }

  return 1;
}


=head2 run

    Title   :   run
    Usage   :   $self->run
    Function:   runs PHYML
    Returns :   none
    Args    :   none
    
=cut

sub run
{
  my $self = shift;
  $self->run_phyml;
}


=head2 write_output

    Title   :   write_output
    Usage   :   $self->write_output
    Function:   parse clustalw output and update family and family_member tables
    Returns :   none
    Args    :   none
    
=cut

sub write_output {
  my $self = shift;

  $self->parse_and_store_proteintree;
}


##########################################
#
# internal methods
#
##########################################

sub get_params {
  my $self         = shift;
  my $param_string = shift;

  return unless($param_string);
  print("parsing parameter string : ",$param_string,"\n") if($self->debug);
  
  my $params = eval($param_string);
  return unless($params);

  if($self->debug) {
    foreach my $key (keys %$params) {
      print("  $key : ", $params->{$key}, "\n");
    }
  }
    
  if(defined($params->{'protein_tree_id'})) {
    $self->{'protein_tree'} =  
         $self->{'comparaDBA'}->get_ProteinTreeAdaptor->
         fetch_node_by_node_id($params->{'protein_tree_id'});
  }
  $self->{'substitution_model'} = $params->{'substitution_model'} if(defined($params->{'substitution_model'}));
  
  return;

}


sub print_params {
  my $self = shift;

  print("params:\n");
  print("  tree_id            : ", $self->{'protein_tree'}->node_id,"\n") if($self->{'protein_tree'});
  print("  substitution_model : ", $self->{'substitution_model'},"\n");
}


sub run_phyml
{
  my $self = shift;


  $self->{'input_aln'} = $self->dumpTreeMultipleAlignmentToWorkdir($self->{'protein_tree'});
  $self->{'newick_file'} = $self->{'input_aln'} . "_phyml_tree.txt ";

  my $phyml_executable = $self->analysis->program_file;
  unless (-e $phyml_executable) {
    $phyml_executable = "/nfs/acari/jessica/bin/alpha-dec-osf4.0/phyml";
    if (-e "/proc/version") {
      # it is a linux machine
      $phyml_executable = "/nfs/acari/jessica/bin/i386/phyml";
    }
  }
  throw("can't find a phyml executable to run\n") unless(-e $phyml_executable);

  #./phyml seqs2 1 i 1 0 JTT 0.0 4 1.0 BIONJ n n 
  my $cmd = $phyml_executable;
  $cmd .= " ". $self->{'input_aln'};  
  if(1) {
    $cmd .= " 0 i 2 0 HKY 4.0 e 1 1.0 BIONJ y y";
  } else {
    $cmd .= " 0 i 1 0"; #AA, interleaved, 1 dataset, no bootstrap
    $cmd .= " ". $self->{'substitution_model'};
    $cmd .= " ". $self->{'transition_transversion_ratio'};
    $cmd .= " ". $self->{'number_of_substitution_rate_categories'};
    $cmd .= " ". $self->{'gamma_distribution_parameter'};
    $cmd .= " BIONJ n n";
  }
  $cmd .= " 2>&1 > /dev/null" unless($self->debug);

  $self->{'comparaDBA'}->dbc->disconnect_when_inactive(1);
  print("$cmd\n") if($self->debug);
  unless(system($cmd) == 0) {
    print("$cmd\n");
    throw("error running phyml, $!\n");
  }
  $self->{'comparaDBA'}->dbc->disconnect_when_inactive(0);

}



########################################################
#
# ProteinTree input/output section
#
########################################################

sub dumpTreeMultipleAlignmentToWorkdir
{
  my $self = shift;
  my $tree = shift;
  
  $self->{'file_root'} = $self->worker_temp_directory. "proteintree_". $tree->node_id;
  $self->{'file_root'} =~ s/\/\//\//g;  # converts any // in path to /

  my $clw_file = $self->{'file_root'} . ".aln";
  return $clw_file if(-e $clw_file);
  print("clw_file = '$clw_file'\n") if($self->debug);

  open(OUTSEQ, ">$clw_file")
    or $self->throw("Error opening $clw_file for write");

  my $sa = $tree->get_SimpleAlign(-id_type => 'MEMBER', -cdna=>1);
  
  my $alignIO = Bio::AlignIO->newFh(-fh => \*OUTSEQ,
                                    -interleaved => 1,
                                    -format => "phylip"
                                   );
  print $alignIO $sa;

  close OUTSEQ;
  
  $self->{'input_aln'} = $clw_file;
  return $clw_file;
}


sub parse_and_store_proteintree
{
  my $self = shift;

  return unless($self->{'protein_tree'});
  
  $self->parse_newick_into_proteintree;
  
  my $treeDBA = $self->{'comparaDBA'}->get_ProteinTreeAdaptor;
  $treeDBA->store($self->{'protein_tree'});
  $treeDBA->delete_nodes_not_in_tree($self->{'protein_tree'});
  $self->{'protein_tree'}->release;
}


sub parse_newick_into_proteintree
{
  my $self = shift;
  my $newick_file =  $self->{'newick_file'};
  my $tree = $self->{'protein_tree'};
  
  #cleanup old tree structure- 
  #  flatten and reduce to only AlignedMember leaves
  $tree->flatten_tree;
  foreach my $node (@{$tree->get_all_leaves}) {
    next if($node->isa('Bio::EnsEMBL::Compara::AlignedMember'));
    $node->disavow_parent;
  }

  #parse newick into a new tree object structure
  my $newick = '';
  print("load from file $newick_file\n") if($self->debug);
  open (FH, $newick_file) or throw("Could not open newick file [$newick_file]");
  while(<FH>) { $newick .= $_;  }
  close(FH);
  my $newtree = $self->{'comparaDBA'}->get_ProteinTreeAdaptor->parse_newick_into_tree($newick);
  
  #leaves of newick tree are named with member_id of members from input tree
  #move members (leaves) of input tree into newick tree to mirror the 'member_id' nodes
  foreach my $member (@{$tree->get_all_leaves}) {
    my $tmpnode = $newtree->find_node_by_name($member->member_id);
    if($tmpnode) {
      $tmpnode->parent->add_child($member);
      $member->distance_to_parent($tmpnode->distance_to_parent);
    } else {
      print("unable to find node in newick for member"); 
      $member->print_member;
    }
  }
  
  # merge the trees so that the children of the newick tree are now attached to the 
  # input tree's root node
  $tree->merge_children($newtree);

  #newick tree is now empty so release it
  $newtree->release;

  #go through merged tree and remove place-holder leaves
  foreach my $node (@{$tree->get_all_leaves}) {
    next if($node->isa('Bio::EnsEMBL::Compara::AlignedMember'));
    $node->disavow_parent;
  }
  $tree->print_tree if($self->debug);
  
  #apply mimized least-square-distance-to-root tree balancing algorithm
  balance_tree($tree);

  $tree->build_leftright_indexing;

  if($self->debug) {
    print("\nBALANCED TREE\n");
    $tree->print_tree;
  }
}



###################################################
#
# tree balancing algorithm
#   find new root which minimizes least sum of squares 
#   distance to root
#
###################################################

sub balance_tree
{
  my $tree = shift;
  
  my $starttime = time();
  
  my $last_root = Bio::EnsEMBL::Compara::NestedSet->new->retain;
  $last_root->merge_children($tree);
  
  my $best_root = $last_root;
  my $best_weight = calc_tree_weight($last_root);
  
  my @all_nodes = $last_root->get_all_subnodes;
  
  foreach my $node (@all_nodes) {
    $node->retain->re_root;
    $last_root->release;
    $last_root = $node;
    
    my $new_weight = calc_tree_weight($node);
    if($new_weight < $best_weight) {
      $best_weight = $new_weight;
      $best_root = $node;
    }
  }
  #printf("%1.3f secs to run balance_tree\n", (time()-$starttime));

  $best_root->retain->re_root;
  $last_root->release;
  $tree->merge_children($best_root);
  $best_root->release;
}

sub calc_tree_weight
{
  my $tree = shift;

  my $weight=0.0;
  foreach my $node (@{$tree->get_all_leaves}) {
    my $dist = $node->distance_to_root;
    $weight += $dist * $dist;
  }
  return $weight;  
}


1;
