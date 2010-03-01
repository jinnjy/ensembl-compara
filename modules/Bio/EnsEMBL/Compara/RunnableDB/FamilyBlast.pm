package Bio::EnsEMBL::Compara::RunnableDB::FamilyBlast;

use strict;
use FileHandle;

use base ('Bio::EnsEMBL::Hive::ProcessWithParams');

sub load_fasta_sequences_from_db {
    my ($self, $start_seq_id, $minibatch, $overwrite) = @_;

    my $offset                  = $self->param('offset')      || 0;
    my $idprefixed              = $self->param('idprefixed')  || 0;
    my $debug                   = $self->debug() || $self->param('debug') || 0;

    my $sql = qq {
        SELECT s.sequence_id, m.stable_id, s.sequence
          FROM member m, sequence s
    }.($overwrite ? '' : ' LEFT JOIN mcl_sparse_matrix x ON (s.sequence_id+?)=x.row_id ')
    .qq{
         WHERE s.sequence_id BETWEEN ? AND ?
           AND m.sequence_id=s.sequence_id
    }.($overwrite ? '' : ' AND x.row_id IS NULL ')
    .qq{
      GROUP BY s.sequence_id
      ORDER BY s.sequence_id
    };

    if($debug) {
        print "SQL:  $sql\n";
    }

    my $sth = $self->dbc->prepare( $sql );
    $sth->execute( ($overwrite ? () : ($offset)), $start_seq_id, $start_seq_id+$minibatch-1 );

    my @fasta_list = ();
    while( my ($seq_id, $stable_id, $seq) = $sth->fetchrow() ) {
        $seq=~ s/(.{72})/$1\n/g;
        chomp $seq;
        push @fasta_list, ($idprefixed
                                ? ">seq_id_${seq_id}_${stable_id}\n$seq\n"
                                : ">$stable_id sequence_id=$seq_id\n$seq\n") ;
    }
    $sth->finish();
    $self->dbc->disconnect_when_inactive(1);

    return \@fasta_list;
}

sub load_name2index_mapping_from_db {
    my ($self) = @_;

    my $sql = qq {
        SELECT sequence_id, stable_id
          FROM member
         WHERE sequence_id
      GROUP BY sequence_id
    };

    my $sth = $self->dbc->prepare( $sql );
    $sth->execute();

    my %name2index = ();
    while( my ($seq_id, $stable_id) = $sth->fetchrow() ) {
        $name2index{$stable_id} = $seq_id;
    }
    $sth->finish();
    $self->dbc->disconnect_when_inactive(1);

    return \%name2index;
}

sub load_name2index_mapping_from_file {
    my ($self, $filename) = @_;

    my %name2index = ();
    open(MAPPING, "<$filename") || die "Could not open name2index mapping file '$filename'";
    while(my $line = <MAPPING>) {
        chomp $line;
        my ($idx, $stable_id) = split(/\s+/,$line);
        $name2index{$stable_id} = $idx;
    }
    close MAPPING;

    return \%name2index;
}

sub name2index { # can load the name2index mapping from db/file if necessary
    my ($self, $name) = @_;

    if($name=~/^seq_id_(\d+)_/) {
        return $1;
    } else {
        my $name2index;
        unless($name2index = $self->param('name2index')) {
            my $tabfile                 = $self->param('tabfile');

            $name2index = $self->param('name2index', $tabfile
                ? $self->load_name2index_mapping_from_file($tabfile)
                : $self->load_name2index_mapping_from_db()
            );
        }
        return $name2index->{$name} || "UNKNOWN($name)";
    }
}

sub fetch_input {
    my $self = shift @_;

    my $start_seq_id            = $self->param('sequence_id') || die "'sequence_id' is an obligatory parameter, please set it in the input_id hashref";
    my $minibatch               = $self->param('minibatch')   || 1;
    my $overwrite               = $self->param('overwrite')   || 0; # overwrite=0 means we only fill in holes, overwrite=1 means we rewrite everything
    my $debug                   = $self->debug() || $self->param('debug') || 0;

    my $fasta_list = $self->load_fasta_sequences_from_db($start_seq_id, $minibatch, $overwrite);

    if($overwrite and scalar(@$fasta_list)<$minibatch) {
        die "Could not load all ($minibatch) sequences, please investigate";
    }

    if($debug) {
        print "Loaded ".scalar(@$fasta_list)." sequences\n";
    }

    $self->param('fasta_list', $fasta_list);

    return 1;
}

sub parse_blast_table_into_matrix_hash {
    my ($self, $filename, $min_self_dist) = @_;

    my $roundto    = $self->param('roundto') || 0.0001;

    my %matrix_hash  = ();

    my $curr_name    = '';
    my $curr_index   = 0;

    open(BLASTTABLE, "<$filename") || die "Could not open the blast table file '$filename'";
    while(my $line = <BLASTTABLE>) {

        if($line=~/^#/) {
            if($line=~/^#\s+Query:\s+(\S+)/) {
                $curr_name  = $1;
                $curr_index = $self->name2index($curr_name)
                    || die "Parser could not map '$curr_name' to sequence_id";

                $matrix_hash{$curr_index}{$curr_index} = $min_self_dist;   # stop losing singletons whose evalue to themselves is *above* 'evalue_limit' threshold
                                                                           # (that is, the ones that are "not even similar to themselves")
            }
        } else {
            my ($qname, $hname, $evalue) = split(/\s+/, $line);

            my $hit_index = $self->name2index($hname);
                # we MUST be explicitly numeric here:
            my $distance  = ($evalue != 0) ? -log($evalue)/log(10) : 200;

                # do the rounding to prevent the unnecessary growth of tables/files
            $distance = int($distance / $roundto) * $roundto;

            $matrix_hash{$curr_index}{$hit_index} = $distance;
        }
    }
    close BLASTTABLE;

    return \%matrix_hash;
}

sub run {
    my $self = shift @_;

    my $fasta_list              = $self->param('fasta_list'); # set by fetch_input()
    my $debug                   = $self->debug() || $self->param('debug') || 0;

    unless(scalar(@$fasta_list)) { # if we have no more work to do just exit gracefully
        if($debug) {
            warn "No work to do, exiting\n";
        }
        return 1;
    }

    my $fastadb                 = $self->param('fastadb')       || die "'fastadb' is an obligatory parameter, please set it in the input_id hashref";
    my $minibatch               = $self->param('minibatch')     || 1;

    my $blast_version           = $self->param('blast_version') || 'ncbi-blast-2.2.22+';
    my $blastp_executable       = $self->param('blastp_exec')   || ( '/software/ensembl/compara/' . $blast_version . '/bin/blastp' );
    my $blast_params            = $self->param('blast_params')  || '-seg yes';
    my $evalue_limit            = $self->param('evalue_limit')  || 0.00001;
    my $tophits                 = $self->param('tophits')       || 250;


    my $blast_infile  = '/tmp/family_blast.in.'.$$;     # only for debugging
    my $blast_outfile = '/tmp/family_blast.out.'.$$;    # looks like inevitable evil (tried many hairy alternatives and failed)

    if($debug) {
        open(FASTA, ">$blast_infile") || die "Could not open '$blast_infile' for writing";
        print FASTA @$fasta_list;
        close FASTA;
    }

    my $cmd = "$blastp_executable -db $fastadb $blast_params -evalue $evalue_limit -num_alignments $tophits -out $blast_outfile -outfmt '7 qacc sacc evalue'";

    if($debug) {
        warn "CMD:\t$cmd\n";
    }

    open( BLAST, "| $cmd") || die "could not execute $blastp_executable, returned error code: $!";
    print BLAST @$fasta_list;
    close BLAST;

    my $matrix_hash = $self->parse_blast_table_into_matrix_hash($blast_outfile, -log($evalue_limit)/log(10) );

    my $incomplete = $self->param('incomplete', (scalar(keys %$matrix_hash) != scalar(@$fasta_list)) );

    unless($debug || $incomplete) {
        unlink $blast_outfile;
    }

    unless($debug) {
        $self->param('matrix_hash', $matrix_hash);        # store it in a parameter
    }

    return 1;
}

sub write_output {
    my $self = shift @_;

    if(my $matrix_hash = $self->param('matrix_hash')) {

        my $offset                  = $self->param('offset') || 0;

        my $sql = "REPLACE INTO mcl_sparse_matrix (row_id, column_id, value) VALUES (?, ?, ?)";

        my $sth = $self->dbc->prepare( $sql );

        while(my($row_id, $subhash) = each %$matrix_hash) {
            while(my($column_id, $value) = each %$subhash) {
                $sth->execute( $row_id + $offset, $column_id + $offset, $value );
            }
        }
        $sth->finish();
    }

    if($self->param('incomplete')) {
        die "According to our parser the table file generated by Blastp is incomplete, please investigate";
    }

    return 1;
}

1;

