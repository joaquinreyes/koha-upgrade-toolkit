#!/usr/bin/perl
# Instala el esquema de Koha y los datos de ejemplo en ingles (MARC21) sin usar el
# instalador web. Equivale a los pasos del instalador web (installer/install.pl).
# Uso (como usuario de la instancia): koha-shell -c "perl install_db.pl" <instancia>
use strict;
use warnings;
use C4::Context;
use C4::Installer;

my $installer = C4::Installer->new();
my $err = $installer->load_db_schema();
die "load_db_schema: $err\n" if $err;

$installer->set_marcflavour_syspref('MARC21');

my @files;
my ( undef, $fw ) = $installer->marc_framework_sql_list( 'en', 'MARC21' );
my ( undef, $sd ) = $installer->sample_data_sql_list('en');
for my $level ( @$fw, @$sd ) {
    push @files, map { $_->{fwkfile} } @{ $level->{frameworks} };
}
local $/ = "\n";
print "Cargando " . scalar(@files) . " archivos de datos\n";
my ( undef, $list ) = $installer->load_sql_in_order( 'en', [], @files );
my $errors = 0;
for my $level (@$list) {
    for my $f ( @{ $level->{fwklist} } ) {
        if ( $f->{error} ) { print "ERROR $f->{fwkname}: $f->{error}\n"; $errors++ }
    }
}
$installer->set_version_syspref();
$installer->set_languages_syspref('en');
print "Version: " . C4::Context->preference('Version') . "\n";
die "Hubo $errors errores cargando datos\n" if $errors;
print "Instalacion de BD completa\n";
