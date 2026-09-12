package AlgaOS::Installer::Util;

use v5.40.0;
use strict;
use warnings;

use JSON qw/from_json to_json/;

use Exporter 'import';

our @EXPORT = qw(to_json_packet to_json from_json);

sub to_json_packet($packet) {
    return to_json($packet) . "\n";
}
1;
