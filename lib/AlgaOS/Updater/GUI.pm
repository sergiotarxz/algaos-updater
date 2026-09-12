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

has app                    => ( is => 'lazy' );
has win                    => ( is => 'rw' );
has const                  => ( is => 'lazy' );
has pipe_name              => ( is => 'ro', required => 1 );
has secret                 => ( is => 'ro', required => 1 );
has _grid_row              => ( is => 'rw', default  => sub { 0 } );
has _scroll                => ( is => 'rw' );
has started_gui            => ( is => 'rw' );
has pid                    => ( is => 'rw' );
has _frontend_shows_update => ( is => 'rw' );
has _have_update           => ( is => 'rw' );

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
        if ( $self->_frontend_shows_update != $self->_have_update ) {
            if ( !$self->_have_update ) {
                $self->_scroll->set_child( $self->_show_no_updates_grid );
            }
            else {
                $self->_scroll->set_child( $self->_show_updates_grid );
            }
            $self->_frontend_shows_update( $self->_have_update );
        }
        return;
    }
    $self->started_gui(1);
    my $const = $self->const;
    my $win   = Gtk::ApplicationWindow->new( $self->app );
    $win->set_title("Actualiza AlgaOS");
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
    $self->_frontend_shows_update($self->_have_update);
    $self->_scroll->set_child(
          $self->_frontend_shows_update
        ? $self->_show_updates_grid
        : $self->_show_no_updates_grid
    );
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
        $self->_have_update( $? == 0 );
        if (   $self->_have_update
            && $self->_have_update != $self->_frontend_shows_update )
        {
            $self->activate;
        }
	# If we didn't act before frontend must
	# act like it knows what happened.
	$self->_frontend_shows_update($self->_have_update);
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
    $self->_have_update(0);
    $self->_frontend_shows_update(0);
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

sub _show_updates_grid($self) {
    my $const = $self->const;
    my $grid  = Gtk::Grid->new;
    $grid->set_valign( $const->GTK_ALIGN_CENTER );
    $grid->set_halign( $const->GTK_ALIGN_CENTER );
    $grid->add_css_class('transparent_background');
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new('Actualiza AlgaOS');
            $label->add_css_class('title-1');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            my $label =
              Gtk::Label->new(
                'Hay actualizaciones disponibles. ¡Actualiza ahora!');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    return $grid;
}

sub _show_no_updates_grid($self) {
    my $const = $self->const;
    my $grid  = Gtk::Grid->new;
    $grid->set_valign( $const->GTK_ALIGN_CENTER );
    $grid->set_halign( $const->GTK_ALIGN_CENTER );
    $grid->add_css_class('transparent_background');
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new('Actualiza AlgaOS');
            $label->add_css_class('title-1');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            my $label =
              Gtk::Label->new('No hay actualizaciones disponibles, todavía...');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    return $grid;
}

1;
