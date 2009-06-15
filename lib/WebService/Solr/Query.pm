package WebService::Solr::Query;

use Moose;

use overload q("") => 'stringify';

my $escape_chars = quotemeta( '+-&|!(){}[]^"~*?:\\' );

has 'query' => ( is => 'ro', isa => 'ArrayRef', default => sub { [] } );

use constant D => 0;
use Data::Dumper;

sub BUILDARGS {
    my $class = shift;

    if ( @_ == 1 && ref $_[ 0 ] && ref $_[ 0 ] eq 'ARRAY' ) {
        return { query => $_[ 0 ] };
    }

    return { query => \@_ };
}

sub stringify {
    my $self = shift;

    return $self->_dispatch_struct( $self->query );
}

sub _dispatch_struct {
    my ( $self, $struct ) = @_;

    my $method = '_struct_' . ref $struct;

    D && $self->___log( "Dispatching to ->$method ". Dumper $struct );

    my $rv = $self->$method( $struct );

    D && $self->___log( "Returned: $rv" );

    return $rv;
}

sub _struct_HASH {
    my ( $self, $struct ) = @_;

    my @clauses;

    for my $k ( keys %$struct ) {
        my $v = $struct->{ $k };

        D && $self->___log("Key => $k, value => ". Dumper($v));

        if ( $k =~ m{^-(.+)} ) {
            my $method = "_op_$1";

            D && $self->___log("Dispatch ->$method ". Dumper($v));
            push @clauses, $self->$method( $v );
        }
        else {
            D && $self->___log("Dispatch ->_dispatch_value $k, ". Dumper($v));
            push @clauses, $self->_dispatch_value( $k, $v );
        }
    }

    my $rv = join( ' AND ', @clauses );

    D && $self->___log("Returning: $rv");

    return $rv;
}

sub _struct_ARRAY {
    my ( $self, $struct ) = @_;

    my $rv = 
          '('
        . join( " OR ", map { $self->_dispatch_struct( $_ ) } @$struct )
        . ')';
        
    D && $self->___log("Returning: $rv");
    
    return $rv;
}

sub _dispatch_value {
    my ( $self, $k, $v ) = @_;

    my $rv;
    ### it's an array ref, the first element MAY be an operator!
    ### it would look something like this:
    # [ '-and',
    #   { '-require' => 'star' },
    #   { '-require' => 'wars' }
    # ];    
    if( ref $v and UNIVERSAL::isa( $v, 'ARRAY' ) and
        defined $v->[0] and $v->[0] =~ /^ - ( AND|OR ) $/ix
    ) {
        ### XXX we're assuming that all the next statements MUST
        ### be hashrefs. is this correct?
        shift @$v;
        my $op = uc $1;

        D && $self->___log("Special operator detected: $op ". Dumper($v));

        my @clauses;
        for my $href ( @$v ) {
            D && $self->___log( 
                "Dispatch ->_dispatch_struct({ $k, ". Dumper($href) .'})' );

            ### the individual directive ($href) pertains to the key, 
            ### so we should send that along.
            my $part = $self->_dispatch_struct( { $k => $href } );
            
            D && $self->___log( "Returned $part" );

            push @clauses, '('. $part .')';
        }
        
        $rv = '('. join( " $op ", @clauses ) .')';

    ### nothing special about this combo, so do a usual dispatch
    } else {        
        my $method = '_value_' . ( ref $v || 'SCALAR' );
        
        D && $self->___log("Dispatch ->$method $k, ". Dumper($v));
        
        $rv = $self->$method( $k, $v );
    }
    
    D && $self->___log("Returning: $rv");
    
    return $rv;
}

sub _value_SCALAR {
    my ( $self, $k, $v ) = @_;    
    $v = $self->escape( $v );
    my $r = qq($k:"$v");
    $r =~ s{^:}{};

    D && $self->___log("Returning: $r");

    return $r;
}

sub _value_HASH {
    my ( $self, $k, $v ) = @_;

    my @clauses;

    for my $op ( keys %$v ) {
        my $struct = $v->{ $op };
        $op =~ s{^-(.+)}{_op_$1};
        
        D && $self->___log("Dispatch ->$op $k, ". Dumper($v));
        
        push @clauses, $self->$op( $k, $struct );
    }

    my $rv = join( ' AND ', @clauses );

    D && $self->___log("Returning: $rv");

    return $rv;
}

sub _value_ARRAY {
    my ( $self, $k, $v ) = @_;

    my $rv = 
        '('
        . join( ' OR ', map { $self->_value_SCALAR( $k, $_ ) } @$v ) . ')';

    D && $self->___log("Returning: $rv");
    
    return $rv;
}

sub _op_default {
    my ( $self, $v ) = @_;
    return $self->_dispatch_value( '', $v );
}

sub _op_range {
    my ( $self, $k ) = ( shift, shift );
    my @v = @{ shift() };
    return "$k:[$v[ 0 ] TO $v[ 1 ]]";
}

*_op_range_inc = \&_op_range;

sub _op_range_exc {
    my ( $self, $k ) = ( shift, shift );
    my @v = @{ shift() };
    return "$k:{$v[ 0 ] TO $v[ 1 ]}";
}

sub _op_boost {
    my ( $self, $k ) = ( shift, shift );
    my ( $v, $boost ) = @{ shift() };
    $v = $self->escape( $v );
    return qq($k:"$v"^$boost);
}

sub _op_fuzzy {
    my ( $self, $k ) = ( shift, shift );
    my ( $v, $distance ) = @{ shift() };
    $v = $self->escape( $v );
    return qq($k:$v~$distance);
}

sub _op_proximity {
    my ( $self, $k ) = ( shift, shift );
    my ( $v, $distance ) = @{ shift() };
    $v = $self->escape( $v );
    return qq($k:"$v"~$distance);
}

sub _op_require {
    my ( $self, $k, $v ) = @_;
    $v = $self->escape( $v );
    return qq(+$k:"$v");
}

sub _op_prohibit {
    my ( $self, $k, $v ) = @_;
    $v = $self->escape( $v );
    return qq(-$k:"$v");
}

sub escape {
    my ( $self, $text ) = @_;
    $text =~ s{([$escape_chars])}{\\$1}g;
    return $text;
}

sub unescape {
    my ( $self, $text ) = @_;
    $text =~ s{\\([$escape_chars])}{$1}g;
    return $text;
}

sub ___log {
    my $self = shift;
    my $msg  = shift;

    ### subroutine the log call came from, and line number the log
    ### call came from. that's 2 different caller frames :(
    my $who  = join ':', [caller(1)]->[3], [caller(0)]->[2];
    
    ### make sure we prefix every line with a #
    $msg =~ s/\n/\n#/g;
    
    print "# $who: $msg\n";
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

WebService::Solr::Query - Abstract query syntax for Solr queries

=head1 ACCESSORS

=over 4

=item * query - stores the original query structure

=back

=head1 METHODS

=head2 new( \%query )

Creates a new query object with the given hashref.

=head2 stringify( )

Converts the supplied structure into a Solr/Lucene query.

=head2 escape( $value )

The following values must be escaped in a search value:

    + - & | ! ( ) { } [ ] ^ " ~ * ? : \

=head2 unescape( $value )

Unescapes values escaped in C<escape()>.

=head1 SEE ALSO

=over 4

=item * L<WebService::Solr>

=back

=head1 AUTHORS

Brian Cassidy E<lt>bricas@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2008-2009 National Adult Literacy Database

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut
