#!/usr/bin/env perl

use v5.42.0;
use strict;
use warnings;

my $pid = shift @ARGV or die "No pid send";
open my $fh, '<', '/proc/' . $pid . '/environ';
my @variables;
{
    local $/ = "\0";
    @variables = <$fh>;
    @variables = map {
        my ( $var, $content ) = /^(.*?)=(.*)\0$/;
        $var . '="' . $content . '"'
    } @variables;
}
use Data::Dumper;
print join "\n", @variables;

