#!/usr/bin/perl
# Genera N registros MARC21 de prueba (ISO2709) con un item cada uno (campo 952).
# Incluye 2 duplicados intencionales (ISBN y titulo+autor) para probar 30-db-maintenance.sh.
# Uso: perl generate_marc.pl salida.mrc [N=50]
use strict;
use warnings;
use MARC::Record;
use MARC::Field;

my ( $out, $n ) = @ARGV;
$n ||= 50;
open my $fh, '>:raw', $out or die "No se puede escribir $out: $!";

my @temas   = qw(Cronicas Historia Poesia Cuentos Ensayos Geografia Biologia Musica Teatro Filosofia);
my @lugares = qw(Valparaiso Santiago Temuco Arica Valdivia Chiloe Atacama Magallanes Rancagua Talca);
my @autores = ( 'Mistral, Gabriela', 'Neruda, Pablo', 'Huidobro, Vicente', 'Parra, Violeta', 'Bombal, Maria Luisa' );

for my $i ( 1 .. $n ) {
    my $tema  = $temas[ $i % @temas ];
    my $lugar = $lugares[ int( $i / @temas ) % @lugares ];
    my $autor = $autores[ $i % @autores ];
    my $isbn  = sprintf( '978956%07d', $i );
    my $title = "$tema de $lugar volumen $i";

    # Duplicados intencionales.
    if ( $i == $n - 1 ) { $isbn = sprintf( '978956%07d', 1 ) }
    if ( $i == $n ) {
        $title = sprintf( '%s de %s volumen %d', $temas[ 2 % @temas ], $lugares[0], 2 );
        $autor = $autores[ 2 % @autores ];
    }

    my $r = MARC::Record->new();
    $r->leader('00000nam a22000007a 4500');
    $r->append_fields(
        MARC::Field->new( '008', '260101s2020    cl            000 0 spa d' ),
        MARC::Field->new( '020', ' ', ' ', a => $isbn ),
        MARC::Field->new( '100', '1', ' ', a => $autor ),
        MARC::Field->new( '245', '1', '0', a => $title ),
        MARC::Field->new( '260', ' ', ' ', a => 'Santiago :', b => 'Editorial de Prueba,', c => '2020.' ),
        MARC::Field->new( '300', ' ', ' ', a => ( 100 + $i ) . ' p.' ),
        MARC::Field->new( '650', ' ', '0', a => $tema ),
        MARC::Field->new( '942', ' ', ' ', c => 'BK' ),
        MARC::Field->new(
            '952', ' ', ' ',
            a => 'CPL', b => 'CPL', y => 'BK',
            p => sprintf( 'TK%06d', $i ),
            o => sprintf( '863 T%03d', $i ),
        ),
    );
    print {$fh} $r->as_usmarc();
}
close $fh;
print "Generados $n registros en $out\n";
