#!/usr/bin/perl
# Cuenta registros indexados en Zebra y opcionalmente busca un termino.
# Uso (como usuario de la instancia, via koha-shell): perl zebra_count.pl [termino]
# Imprime:  total=<n>   y si hay termino: hits=<n>
use strict;
use warnings;
use C4::Context;

my $term = shift @ARGV;
my $conn = C4::Context->Zconn('biblioserver');

# _ALLRECORDS con relacion 103 devuelve todos los registros del indice.
my $rs = $conn->search_pqf('@attr 1=_ALLRECORDS @attr 2=103 ""');
print 'total=', $rs->size(), "\n";

if ( defined $term && length $term ) {
    ( my $q = $term ) =~ s/"/ /g;
    # Busqueda por palabra clave (1=1016 "Any").
    my $rs2 = $conn->search_pqf(qq{\@attr 1=1016 "$q"});
    print 'hits=', $rs2->size(), "\n";
}
