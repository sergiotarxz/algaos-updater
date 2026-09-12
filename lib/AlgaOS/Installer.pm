package AlgaOS::Installer;

use v5.38.0;
use strict;
use warnings;


our $VERSION = "0.001";

require XSLoader;

XSLoader::load(__PACKAGE__, $VERSION);
require AlgaOS::Installer::Parents;
1;
