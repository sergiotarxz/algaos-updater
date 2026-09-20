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
has _is_updating           => ( is => 'rw' );
has _machine_id            => ( is => 'lazy' );
has _tmp_dir               => ( is => 'lazy' );
has _channel_preference    => ( is => 'lazy' );

sub _build__machine_id {
    open my $fh, '<', '/etc/machine-id';
    local $/ = undef;
    my $return = <$fh>;
    $return =~ s/\s+//g;
    return $return;
}

sub _build__channel_preference($self) {
    open my $fh, '<', '/etc/algaos-channel';
    local $/ = undef;
    my $return = <$fh>;
    $return =~ s/\s+//g;
    if ( !grep { $return eq $_ } (qw/latest next stable/) ) {
        $self->notify(
'El actualizador de AlgaOS encontró un valor inesperado en /etc/algaos-channel y sufrió un error, los valores validos son latest y next.'
        );
        die "No channel $return.";
    }
    return $return;
}

sub _build__tmp_dir {
    my $tmp_dir = '/tmp/algaos-updater/';
    system qw{sudo rm -rf},    $tmp_dir;
    system qw{sudo mkdir -pv}, $tmp_dir;
    return $tmp_dir;
}

sub sync_repo($self) {
    my $webrsync_options =
      defined $self->_channel_preference
      ? "?preference=" . $self->_channel_preference
      : "";
    my $file = $self->_tmp_dir . "/webrsync.tar.bz2";
    system qw{sudo rm -rf /var/db/repos/algaos/};
    system qw{sudo mkdir -pv /var/db/repos/algaos/};
    system qw{sudo curl -L -o}, $file,
      "https://algaos.com/dist/" . $self->_machine_id . "/webrsync.tar.bz2$webrsync_options";
    system qw{sudo tar -C /var/db/repos/algaos/ -xvpf}, $file;
}

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
        if ( $self->_is_updating ) {
            $self->_scroll->set_child( $self->_show_updating );
            return;
        }
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
    $self->_frontend_shows_update( $self->_have_update );

    if ( $self->_is_updating ) {
        $self->_scroll->set_child( $self->_show_updating );

    }
    else {
        $self->_scroll->set_child(
              $self->_frontend_shows_update
            ? $self->_show_updates_grid
            : $self->_show_no_updates_grid
        );
    }
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

sub is_there_updates($self) {
    system qw{rm -v /etc/portage/binrepos.conf/gentoo.conf};
    {
        open my $bin_fh, '|-',
          qw{sudo tee /etc/portage/binrepos.conf/algaos.conf}
          or die "open: $!";

        my $binpkg_options =
          defined $self->_channel_preference
          ? "?preference=" . $self->_channel_preference
          : "";
        say $bin_fh <<"EOF";
[algaos]

location = https://algaos.com/dist/@{[$self->_machine_id]}/binpkg$binpkg_options
sync-uri = https://algaos.com/dist/@{[$self->_machine_id]}/binpkg$binpkg_options
priority = 1
verify-signature = false
EOF

        close $bin_fh or die "tee: $?";
    }
    $self->sync_repo;

    my $output = `emerge -p --getbinpkg -uUDN \@world --with-bdeps=y`;
    say $output;

    my $updatable = $output =~ /^\[(?:ebuild|binary)\s+/m;

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
        if ( $self->_have_update ) {
            $self->notify(
'Hay actualizaciones disponibles, para mantener su ordenador seguro actualice ahora.'
            );
        }
        if (   $self->_have_update
            && $self->_have_update != $self->_frontend_shows_update )
        {
            $self->activate;
        }

        # If we didn't act before frontend must
        # act like it knows what happened.
        $self->_frontend_shows_update( $self->_have_update );
        $self->pid(0);
        return 0;
    }
    return 1;
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
            my $label = Gtk::Label->new('Hay actualizaciones disponibles…');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            my $button = Gtk::Button->new('¡Actualiza ahora!');
            $button->connect(
                'clicked',
                sub {
                    $self->_update;
                }
            );
            $grid->attach( $button, 0, $self->_grid_row, 3, 1 );
        }
    );
    return $grid;
}

sub _update($self) {
    $self->_is_updating(1);
    $self->_have_update(1);
    $self->_frontend_shows_update(1);
    $self->activate;
    my $pid = fork;
    if ( !$pid ) {
        if ( system qw{sudo emerge -uUDN portage algaos-updater} ) {
            exit 1;
        }
        if (
            system
            qw{sudo emerge --noreplace --getbinpkg @world --with-bdeps=y} )
        {
            exit 1;
        }
        if ( system qw{sudo emerge --getbinpkg -uUDN @world --with-bdeps=y} ) {
            exit 1;
        }
        if ( system qw{sudo emerge --depclean} ) {
            exit 1;
        }
        my @services = qw/power-profiles-daemon/;
        for my $service (@services) {
            system qw{sudo systemctl enable --now}, $service;
        }
        exit 0;
    }
    $self->app->timeout_add(
        1000,
        sub {
            if ( 0 < waitpid $pid, WNOHANG ) {
                say 'Update finished';
                $self->notify('La actualización terminó');
                $self->_have_update(0);
                $self->_is_updating(0);
                $self->_frontend_shows_update(1);
                $self->activate;
                return 0;
            }
            say 'Waiting another second for update finish';
            return 1;
        }
    );
}

sub notify( $self, $description ) {
    system qw{notify-send --icon com.algaos.Updater}, 'Actualiza AlgaOS',
      $description, '-a',
      'Actualizador AlgaOS';
}

sub _show_updating($self) {
    my $grid  = Gtk::Grid->new;
    my $const = $self->const;
    $grid->set_valign( $const->GTK_ALIGN_CENTER );
    $grid->set_halign( $const->GTK_ALIGN_CENTER );
    $grid->add_css_class('transparent_background');
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new('Actualizando AlgaOS');
            $label->add_css_class('title-1');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new(
                'Espera pacientemente, apagar el 
ordenador ahora puede causar daños en 
el software no cubiertos por la garatia.'
            );
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
