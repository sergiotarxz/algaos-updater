use v5.38.0;
use Module::Build;

my @types = (
    [ 'Gtk::Application',    'GtkApplication',    'GTK_APPLICATION' ],
    [ 'Gio::Application',    'GApplication',      'G_APPLICATION' ],
    [ 'Gtk::Box',            'GtkBox',            'GTK_BOX' ],
    [ 'Gtk::Window',         'GtkWindow',         'GTK_WINDOW' ],
    [ 'Gtk::ScrolledWindow', 'GtkScrolledWindow', 'GTK_SCROLLED_WINDOW' ],
    [
        'Gtk::ApplicationWindow', 'GtkApplicationWindow',
        'GTK_APPLICATION_WINDOW'
    ],
    [ 'Gtk::Overlay',     'GtkOverlay',     'GTK_OVERLAY' ],
    [ 'G::Object',        'GObject',        'G_OBJECT' ],
    [ 'Gtk::Widget',      'GtkWidget',      'GTK_WIDGET' ],
    [ 'Gtk::Button',      'GtkButton',      'GTK_BUTTON' ],
    [ 'Gtk::CheckButton', 'GtkCheckButton', 'GTK_CHECK_BUTTON' ],
    [ 'Gtk::Entry',       'GtkEntry',       'GTK_ENTRY' ],
    [ 'Gtk::Dropdown',    'GtkDropDown',    'GTK_DROP_DOWN' ],
    [ 'Gtk::Picture',     'GtkPicture',     'GTK_PICTURE' ],
    [ 'Gio::File',        'GFile',          'G_FILE' ],
    [ 'Gdk::Texture',     'GdkTexture',     'GDK_TEXTURE' ],
    [ 'Gdk::Display',     'GdkDisplay',     'GDK_DISPLAY' ],
    [ 'Gtk::CssProvider', 'GtkCssProvider', 'GTK_CSS_PROVIDER' ],
    [ 'Gtk::Grid',        'GtkGrid',        'GTK_GRID' ],
    [ 'Gtk::Label',       'GtkLabel',       'GTK_LABEL' ],
    [ 'Gtk::Editable',    'GtkEditable',    'GTK_EDITABLE' ],
    [ 'Gtk::AlertDialog', 'GtkAlertDialog', 'GTK_ALERT_DIALOG' ],
);

my @constants = (
    ['GTK_ALIGN_FILL'],           ['GTK_ALIGN_START'],
    ['GTK_ALIGN_END'],            ['GTK_ALIGN_CENTER'],
    ['GTK_ORIENTATION_VERTICAL'], ['GTK_STYLE_PROVIDER_PRIORITY_APPLICATION'],
    ['G_BINDING_SYNC_CREATE'],    ['G_BINDING_DEFAULT'],
);

my %parentships = (
    'Gio::Application'       => [ 'G::Object', ],
    'G::File'                => [ 'G::Object', ],
    'Gdk::Texture'           => [ 'G::Object', ],
    'Gdk::Display'           => [ 'G::Object', ],
    'Gtk::Widget'            => [ 'G::Object', ],
    'Gtk::CssProvider'       => [ 'G::Object', ],
    'Gtk::AlertDialog'       => [ 'G::Object', ],
    'Gtk::Application'       => [ 'Gio::Application', ],
    'Gtk::Overlay'           => ['Gtk::Widget'],
    'Gtk::Window'            => [ 'Gtk::Widget', ],
    'Gtk::Dropdown'          => [ 'Gtk::Widget', ],
    'Gtk::ScrolledWindow'    => [ 'Gtk::Widget', ],
    'Gtk::Entry'             => [ 'Gtk::Widget', 'Gtk::Editable', ],
    'Gtk::Picture'           => [ 'Gtk::Widget', ],
    'Gtk::Grid'              => [ 'Gtk::Widget', ],
    'Gtk::Button'            => [ 'Gtk::Widget', ],
    'Gtk::CheckButton'       => [ 'Gtk::Widget', ],
    'Gtk::Box'               => [ 'Gtk::Widget', ],
    'Gtk::Label'             => [ 'Gtk::Widget', ],
    'Gtk::ApplicationWindow' => [ 'Gtk::Window', ],
);

generate_typemap();
generate_typedefs();
generate_parentships();
generate_constants_xsi();

sub generate_constants_xsi {
    open my $fh, '>', 'lib/AlgaOS/Constants.xsi'
      or die "Cannot create Constants.xsi: $!";
    say $fh "MODULE = AlgaOS::Installer PACKAGE = AlgaOS::Installer::Constants";

    say $fh "";

    for my $c (@constants) {
        my ($c_name) = @$c;

        say $fh <<"XS";
unsigned int
$c_name(...)
CODE:
    RETVAL = (unsigned int) $c_name;
OUTPUT:
    RETVAL
XS
    }

    say $fh <<"XS";
AlgaOS::Installer::Constants
new(...)
    CODE:
        RETVAL = malloc(sizeof *RETVAL);
        *RETVAL = 1;
    OUTPUT:
        RETVAL

void
DESTROY(AlgaOS::Installer::Constants self)
    CODE:
        free(self);
XS
}

sub generate_parentships {
    open my $fh, '>', 'lib/AlgaOS/Installer/Parents.pm'
      or die "Cannot create parentships: $!";
    for my $child ( keys %parentships ) {
        say $fh "package $child;";
        say $fh "use v5.38.0;";
        say $fh "use vars qw/\@ISA/;";
        say $fh "our \@ISA = qw/@{[join ' ', @{$parentships{$child}}]}/;";
    }
}

my $build = Module::Build->new(
    module_name => 'AlgaOS::Installer',
    license     => 'perl',
    requires    => {
        'perl'               => '5.38.2',
        'ExtUtils::CBuilder' => 0,
        'Crypt::URandom'     => 0,
        'Moo'                => 0,
        'PBKDF2::Tiny'       => 0,
        'JSON'               => 0,
	'File::ShareDir'     => 0,
    },
    script_files => [
        'scripts/algaos-installer',
    ],
    share_dir => 'share',
    extra_compiler_flags => scalar `pkg-config --cflags gtk4` . " -I$ENV{PWD}",
    extra_linker_flags   => scalar `pkg-config --libs gtk4`,
);

$build->create_build_script;

sub generate_typemap {
    open my $pre_fh, '<', 'pre_typemap';
    local $/ = undef;
    my $pre_file = <$pre_fh> // '';
    open my $fh, '>', 'typemap'
      or die "Cannot create typemap: $!";

    say $fh "TYPEMAP";
    say $fh "
$pre_file
    ";
    for my $row (@types) {
        my $perl_class = $row->[0];
        my $c_constant = $row->[1];
        my $c_class    = $row->[2];
        say $fh "
$perl_class T_PTROBJ_GOBJECT_$c_class

$c_constant * T_PTROBJ_GOBJECT_$c_class
";
    }
    say $fh "INPUT";
    for my $row (@types) {
        my $perl_class         = $row->[0];
        my $c_constant         = $row->[1];
        my $c_class            = $row->[2];
        my $c_class_lower_case = lc($c_class);
        say $fh "
T_PTROBJ_GOBJECT_$c_class
    if (sv_isobject(\$arg)) {
        IV integer_pointer = SvIV(SvRV(\$arg));
        void *void_object = INT2PTR(void *, integer_pointer);
        if (G_IS_OBJECT(void_object)) {
            GObject *gobject = G_OBJECT (void_object);
            if (G_TYPE_CHECK_INSTANCE_TYPE(gobject, ${c_class_lower_case}_get_type())) {
                \$var = $c_class (gobject);
            } else {
                croak(\"Not implementing $c_class\");
            }
        } else {
            croak(\"Expected gobject\");
        }
    } else {
        croak(\"Expected $perl_class object\");
    }
";
    }

    say $fh "OUTPUT";

    for my $row (@types) {
        my $perl_class = $row->[0];
        my $c_class    = $row->[2];

        say $fh "
T_PTROBJ_GOBJECT_$c_class
    sv_setref_pv(\$arg, \"$perl_class\", (void *)\$var);
";
    }
}

sub generate_typedefs {
    open my $pre_fh, '<', 'pre_typedef.h';
    local $/ = undef;
    my $pre_file = <$pre_fh> // '';
    open my $fh, '>', 'typedefs.h'
      or die "Cannot create typedefs.h: $!";
    say $fh $pre_file;
    for my $row (@types) {
        my $perl_class         = $row->[0];
        my $c_constant         = $row->[1];
        my $c_class            = $row->[2];
        my $c_class_lower_case = lc($c_class);
        say $fh "typedef $c_constant *" . ( $perl_class =~ s/::/__/gr ) . ';';
    }
}
