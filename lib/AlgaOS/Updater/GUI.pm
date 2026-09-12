package AlgaOS::Updater::GUI;

use v5.40.0;
use strict;
use warnings;

use Moo;
use AlgaOS::Updater;
use List::Util;
use JSON;
use POSIX qw/WNOHANG/;
use PBKDF2::Tiny;
use Crypt::URandom qw/urandom/;
use File::ShareDir ':ALL';
my $dist_dir_files = dist_dir('AlgaOS-Updater');

my @perl_args_chroot = @ARGV;

BEGIN {
    *CORE::GLOBAL::exit = sub {
        POSIX::_exit( $_[0] // 0 );
    };
}

has app         => ( is => 'lazy' );
has win         => ( is => 'rw' );
has const       => ( is => 'lazy' );
has pipe_name   => ( is => 'ro', required => 1 );
has secret      => ( is => 'ro', required => 1 );
has _grid_row   => ( is => 'rw', default  => sub { 0 } );
has _scroll     => ( is => 'rw' );
has started_gui => ( is => 'rw' );
has pid         => ( is => 'rw' );

sub call_and_increment_grid_row( $self, $coderef ) {
    $coderef->();
    $self->_grid_row( $self->_grid_row + 1 );
}

sub _build_const {
    return AlgaOS::Updater::Constants->new;
}

sub _build_app {
    return Gtk::Application->new( "com.algaos.Updater", 0 );
}

sub activate($self) {
    if ( $self->started_gui ) {
        return;
    }
    $self->started_gui(1);
    my $const = $self->const;
    my $win   = Gtk::ApplicationWindow->new( $self->app );
    $win->set_title("Update AlgaOS");
    my $display  = $win->get_display;
    my $provider = Gtk::CssProvider->new;
    $provider->load_from_path( $dist_dir_files . '/style.css' );
    $display->add_css_provider( $provider,
        $const->GTK_STYLE_PROVIDER_PRIORITY_APPLICATION );
    my $width  = 400;
    my $height = ( 365 * 440 ) / 770;
    $win->set_default_size( $width, $height );
    $win->set_resizable(0);
    $self->win($win);
    my $overlay = Gtk::Overlay->new;
    my $file    = Gio::File->new( $dist_dir_files . '/beach0.jpg' );
    my $texture = Gdk::Texture->new($file);
    my $picture = Gtk::Picture->new($texture);
    $picture->set_size_request( $width, $height );
    $overlay->set_child($picture);
    my $scroll = Gtk::ScrolledWindow->new;
    $self->_scroll($scroll);
    $overlay->add_overlay($scroll);
    $win->set_child($overlay);
    $win->connect(
        'close-request' => sub {
            $self->win(undef);
            $self->started_gui(0);
            return 0;
        }
    );
    $win->present;
}

sub is_there_updates {
    my $output = `emerge -p --quiet -uUDN \@system`;

    my $updatable = $output =~ /^\[(?:ebuild|binary)\s+/;

    if ($updatable) {
        exit 0;
    }
    else {
        exit 1;
    }
}

sub _check_pid($self) {
    if ( 0 < waitpid $self->pid, WNOHANG ) {
        $self->activate if $? == 0;
        $self->pid(0);
        return 1;
    }
    return 0;
}

sub _start_pid($self) {
    $self->pid(fork);
    if ( !$self->pid ) {
        $self->is_there_updates;
    }
}

sub _handle_pid($self) {
    if ( $self->pid ) {
        $self->_check_pid;
    }
    else {
        $self->_start_pid;
    }
}

sub _handle_pid_and_schedule($self) {
    my $multiply_by_hour = 0;
    my $time             = 1000;
    $self->_handle_pid;
    if ( !$self->pid ) {
        $multiply_by_hour = 1;
    }
    if ($multiply_by_hour) {
        $time *= 3600;
    }
    say "Waiting @{[$time / 1000]} seconds";
    $self->app->timeout_add(
        $time,
        sub {
            $self->_handle_pid_and_schedule;
            return 0;
        }
    );
    return 0;
}

sub run($self) {
    $self->app->connect(
        'startup' => sub {
            $self->app->timeout_add(
                3000,
                sub {
                    $self->_handle_pid_and_schedule;
                }
            );
        }
    );
    $self->app->connect(
        'activate' => sub {
            $self->activate;
        }
    );

    $self->app->hold;
    $self->app->run(@ARGV);
}
1;
