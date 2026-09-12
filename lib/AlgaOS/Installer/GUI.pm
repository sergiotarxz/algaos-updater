package AlgaOS::Installer::GUI;

use v5.40.0;
use strict;
use warnings;

use Moo;
use AlgaOS::Installer;
use AlgaOS::Installer::Util;
use List::Util;
use JSON;
use POSIX qw/WNOHANG/;
use PBKDF2::Tiny;
use Crypt::URandom qw/urandom/;
use File::ShareDir ':ALL';
my $dist_dir_files = dist_dir('AlgaOS-Installer');

my @perl_args_chroot = @ARGV;

BEGIN {
    *CORE::GLOBAL::exit = sub {
        POSIX::_exit( $_[0] // 0 );
    };
}

has app                            => ( is => 'lazy' );
has win                            => ( is => 'rw' );
has const                          => ( is => 'lazy' );
has pipe_name                      => ( is => 'ro', required => 1 );
has secret                         => ( is => 'ro', required => 1 );
has _grid_row                      => ( is => 'rw', default  => sub { 0 } );
has _proxy_started                 => ( is => 'rw' );
has _hostname_entry                => ( is => 'rw' );
has _username_entry                => ( is => 'rw' );
has _password_entry                => ( is => 'rw' );
has _start_installation_button     => ( is => 'rw' );
has _proxy_others                  => ( is => 'rw' );
has _dropdown_timezones            => ( is => 'rw' );
has _dropdown_locale               => ( is => 'rw' );
has _dropdown_block_devices        => ( is => 'rw' );
has _dropdown_recover_or_reinstall => ( is => 'rw' );
has _scroll                        => ( is => 'rw' );
has _recovery_uuid                 => ( is => 'rw' );
has _root_uuid                     => ( is => 'rw' );
has _efi_uuid                      => ( is => 'rw' );
has _current_recovery_partition    => ( is => 'lazy' );
has _install_is_recover            => ( is => 'rw' );

sub excfailexit {
    my @command        = @_;
    my $command_string = join ', ', map { "'$_'" } @command;
    say "system $command_string";
    my $return_code = system @command;
    if ($return_code) {
        system 'sudo umount -R /mnt/gentoo';
        system 'sudo umount -R /recovery';
        say "system $command_string: failed";
        exit 1;
    }
}
excfailexit qw{sudo mkdir -pv /mnt/gentoo/};

sub call_and_increment_grid_row( $self, $coderef ) {
    $coderef->();
    $self->_grid_row( $self->_grid_row + 1 );
}

sub _build_const {
    return AlgaOS::Installer::Constants->new;
}

sub _build_app {
    return Gtk::Application->new( "com.algaos.Installer", 0 );
}

sub _create_install_grid( $self, $desc ) {
    my $grid  = Gtk::Grid->new;
    my $const = $self->const;
    $grid->add_css_class('transparent_background');
    $self->_grid_row(0);
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new('Install AlgaOS');
            $label->add_css_class('title-1');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new($desc);
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $grid->set_valign( $const->GTK_ALIGN_CENTER );
    $grid->set_halign( $const->GTK_ALIGN_CENTER );
    return $grid;
}

sub _overwrite_install_generic( $self, %args ) {
    my $disk_prepare = $args{disk_prepare};
    if ( !defined $disk_prepare ) {
        die 'disk_prepare callback not sent';
    }
    my $container_block = $args{container_block};
    my $const           = $self->const;
    my $grid            = Gtk::Grid->new;
    $grid->add_css_class('transparent_background');
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new('Install AlgaOS');
            $label->add_css_class('title-1');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( Gtk::Label->new('Select hostname'),
                0, $self->_grid_row, 1, 1 );
            $grid->attach( $self->_hostname_entry, 1, $self->_grid_row, 1, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( Gtk::Label->new('New user name'),
                0, $self->_grid_row, 1, 1 );
            $grid->attach( $self->_username_entry, 1, $self->_grid_row, 1, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( Gtk::Label->new('New user password'),
                0, $self->_grid_row, 1, 1 );
            $grid->attach( $self->_password_entry, 1, $self->_grid_row, 1, 1 );
        }
    );

    my $is_national = sub {
        my $nation = shift;
        return List::Util::any { $_ eq $nation }
        (qw{Europe/Madrid Africa/Ceuta Atlantic/Canary});
    };

    my $is_europe = sub {
        my $region = shift;
        return $region =~ /Europe/;
    };

    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( Gtk::Label->new('Set your timezone'),
                0, $self->_grid_row, 1, 1 );
            my @timezones = split /\s+/s, `timedatectl list-timezones`;
            @timezones = grep { defined $_ } @timezones;
            @timezones = sort {
                return
                     ( $b eq 'Europe/Madrid' ) <=> ( $a eq 'Europe/Madrid' )
                  || $is_national->($b)        <=> $is_national->($a)
                  || $is_europe->($b)          <=> $is_europe->($a)
                  || $a cmp $b;
            } @timezones;
            my $dropdown = Gtk::Dropdown->new( [@timezones] );
            $self->_dropdown_timezones($dropdown);
            $grid->attach( $dropdown, 1, $self->_grid_row, 1, 1 );
        }
    );

    my $is_spain_spanish = sub {
        my $lang = shift;
        return $lang =~ /^es_ES/;
    };
    my $is_spanish = sub {
        my $lang = shift;
        return $lang =~ /^es/;
    };
    my $is_english = sub {
        my $lang = shift;
        return $lang =~ /^en/;
    };
    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( Gtk::Label->new('Set your language and region'),
                0, $self->_grid_row, 1, 1 );
            my @locales = split /\s+/s, `locale -a`;
            @locales = grep { defined $_ && $_ =~ /utf8/ } @locales;
            @locales = sort {
                return
                     $is_spain_spanish->($b) <=> $is_spain_spanish->($a)
                  || $is_spanish->($b)       <=> $is_spanish->($a)
                  || $is_english->($b)       <=> $is_english->($a)
                  || $a cmp $b;
            } @locales;
            my $dropdown = Gtk::Dropdown->new( [@locales] );
            $self->_dropdown_locale($dropdown);
            $grid->attach( $dropdown, 1, $self->_grid_row, 1, 1 );
        }
    );
    my $confirm_button =
      Gtk::Button->new("Install in this disk and lose all data");
    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( $confirm_button, 1, $self->_grid_row, 1, 1 );
        }
    );
    $confirm_button->connect(
        clicked => sub {
            my $dialog = Gtk::AlertDialog->new(
                "Your data in that storage media will be lost",
                "Ready to format?" );
            $dialog->make_yes_no();
            $dialog->choose(
                $self->win,
                sub($button) {
                    if ( $button != 1 ) {
                        return;
                    }
                    $self->_install(
                        container_block => $container_block,
                        hostname        => $self->_hostname_entry->get_text,
                        username        => $self->_username_entry->get_text,
                        password        => $self->_password_entry->get_text,
                        timezone => $self->_dropdown_timezones->selected_text,
                        locale   => $self->_dropdown_locale->selected_text,
                        complete_systemd => 1,
                        prepare          => sub {
                            $disk_prepare->();
                            system 'sudo mkdir /recovery';

                            system qw{sudo mount},
                              $self->_current_recovery_partition, '/recovery';
                            excfailexit
'sudo tar -C /mnt/gentoo -xvpf /stage3-algaos-latest.tar.xz --numeric-owner --xattrs-include="*.*"';
                            excfailexit qw{sudo cp -Lv}, '/etc/resolv.conf',
                              '/mnt/gentoo/etc/';
                            excfailexit
                              qw{sudo rsync -P -a -v /recovery/rootfs.squashfs /mnt/gentoo/recovery/};

                        }
                    );
                }
            );
        }
    );

    $grid->set_valign( $const->GTK_ALIGN_CENTER );
    $grid->set_halign( $const->GTK_ALIGN_CENTER );
    return $grid;
}

sub _create_real_install_grid($self) {
    my ($block_name) = split /\t+/,
      $self->_dropdown_block_devices->selected_text;
    my $block          = "/dev/$block_name";
    my $efi_block      = "${block}1";
    my $recovery_block = "${block}3";
    my $root_block     = "${block}4";
    $self->_overwrite_install_generic(
        container_block => $block,
        disk_prepare    => sub(%args) {
            system qw{sudo sgdisk -Z}, $block;
            excfailexit qw{sudo sgdisk -n 1::+1G},  $block;
            excfailexit qw{sudo sgdisk -t 1:ef00},  $block;
            excfailexit qw{sudo sgdisk -c},         "1:AlgaOSEFI", $block;
            excfailexit qw{sudo sgdisk -n 2::+1G},  $block;
            excfailexit qw{sudo sgdisk -t 2:ef02},  $block;
            excfailexit qw{sudo sgdisk -c},         "2:AlgaOSBIOSBoot", $block;
            excfailexit qw{sudo sgdisk -n 3::+20G}, $block;
            excfailexit qw{sudo sgdisk -c},         "3:AlgaOSRecovery", $block;
            excfailexit qw{sudo sgdisk -N 4},       $block;
            excfailexit qw{sudo sgdisk -c},         "4:AlgaOSRoot", $block;
            excfailexit qw{sudo dd if=/dev/zero bs=5M count=10},
              "of=$efi_block";
            excfailexit qw{sudo dd if=/dev/zero bs=5M count=10},
              "of=$recovery_block";
            excfailexit qw{sudo dd if=/dev/zero bs=5M count=10},
              "of=$root_block";
            excfailexit qw{sudo mkfs.vfat}, $efi_block;
            excfailexit qw{sudo mkfs.ext4}, $recovery_block;
            excfailexit qw{sudo mkfs.ext4}, $root_block;
            excfailexit qw{sudo mount},     $root_block, '/mnt/gentoo';
            excfailexit qw{sudo mkdir -pv}, '/mnt/gentoo/recovery';
            excfailexit qw{sudo mount}, $recovery_block, '/mnt/gentoo/recovery';
            excfailexit qw{sudo mkdir -pv}, '/mnt/gentoo/boot/efi';
            excfailexit qw{sudo mount},     $efi_block, '/mnt/gentoo/boot/efi';
        }
    );
}

sub _build__current_recovery_partition($self) {
    my $cmdline = `cat /proc/cmdline`;
    my ($partition) = $cmdline =~ /live:(\S+)/;
    return $partition;
}

sub _create_main_grid($self) {
    my $const = $self->const;
    my $grid  = Gtk::Grid->new;
    $grid->add_css_class('transparent_background');
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new('Install AlgaOS');
            $label->add_css_class('title-1');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( Gtk::Label->new('Set the installation destination'),
                0, $self->_grid_row, 1, 1 );
            my $block_devices =
              JSON::from_json(`lsblk --json -d -o NAME,SIZE,MODEL,TYPE,TRAN`);
            my @block_devices =
              map {
                join "\t", map { $_ // '' } @$_{qw/name model size type tran/};
              } $block_devices->{blockdevices}->@*;
            @block_devices = grep { defined $_ } @block_devices;
            my $dropdown = Gtk::Dropdown->new( [@block_devices] );
            $self->_dropdown_block_devices($dropdown);
            $grid->attach( $dropdown, 1, $self->_grid_row, 1, 1 );
        }
    );

    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( $self->_start_installation_button,
                1, $self->_grid_row, 1, 1 );
        }
    );
    $self->_start_installation_button->connect(
        clicked => sub {
            $self->_on_click_select_media;
        }
    );

    $grid->set_valign( $const->GTK_ALIGN_CENTER );
    $grid->set_halign( $const->GTK_ALIGN_CENTER );
    return $grid;
}

sub _create_recover_installation_grid($self) {
    my $const = $self->const;
    my $grid  = Gtk::Grid->new;
    $grid->add_css_class('transparent_background');
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new('Install AlgaOS');
            $label->add_css_class('title-1');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            $grid->attach( Gtk::Label->new('Recover AlgaOS or reinstall it?'),
                0, $self->_grid_row, 1, 1 );
            my $dropdown = Gtk::Dropdown->new( [qw/Recover Reinstall/] );
            $self->_dropdown_recover_or_reinstall($dropdown);
            $grid->attach( $dropdown, 1, $self->_grid_row, 1, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            my $button = Gtk::Button->new('Continue');
            $button->connect(
                clicked => sub {
                    if ( $self->_dropdown_recover_or_reinstall->selected_text eq
                        'Reinstall' )
                    {
                        $self->_scroll->set_child(
                            $self->_overwrite_installation_menu );
                        return;
                    }
                    system qw{sudo mount}, $self->_root_uuid, '/mnt/gentoo';
                    $self->_restore_system( '/stage3-algaos-latest.tar.xz',
                        '/mnt/gentoo', 1 );
                }
            );
            $grid->attach( $button, 1, $self->_grid_row, 1, 1 );
        }
    );

    $grid->set_valign( $const->GTK_ALIGN_CENTER );
    $grid->set_halign( $const->GTK_ALIGN_CENTER );
    return $grid;
}

sub _overwrite_installation_menu($self) {
    my ($block_name) = split /\t+/,
      $self->_dropdown_block_devices->selected_text;
    my $block          = "/dev/$block_name";
    my $efi_block      = 'PARTUUID=' . $self->_efi_uuid;
    my $recovery_block = 'PARTUUID=' . $self->_recovery_uuid;
    my $root_block     = 'PARTUUID=' . $self->_root_uuid;
    $self->_overwrite_install_generic(
        container_block => $block,
        disk_prepare    => sub(%args) {
            excfailexit qw{sudo dd if=/dev/zero bs=1M count=10},
              'of=/dev/disk/by-partuuid/' . $self->_root_uuid;
            excfailexit qw{sudo mkfs.ext4},
              '/dev/disk/by-partuuid/' . $self->_root_uuid;
            excfailexit qw{sudo dd if=/dev/zero bs=1M count=10},
              'of=/dev/disk/by-partuuid/' . $self->_recovery_uuid;
            excfailexit qw{sudo mkfs.ext4},
              '/dev/disk/by-partuuid/' . $self->_recovery_uuid;
            excfailexit qw{sudo dd if=/dev/zero bs=1M count=10},
              'of=/dev/disk/by-partuuid/' . $self->_efi_uuid;
            excfailexit qw{sudo mkfs.vfat},
              '/dev/disk/by-partuuid/' . $self->_efi_uuid;
            excfailexit qw{sudo mkdir -pv /mnt/gentoo/};
            excfailexit qw{sudo mount},     $root_block, '/mnt/gentoo';
            excfailexit qw{sudo mkdir -pv}, '/mnt/gentoo/recovery';
            excfailexit qw{sudo mount}, $recovery_block, '/mnt/gentoo/recovery';
            excfailexit qw{sudo mkdir -pv}, '/mnt/gentoo/boot/efi';
            excfailexit qw{sudo mount},     $efi_block, '/mnt/gentoo/boot/efi';
        }
    );
}

# TODO: Slop function, in Chatyipity we trust
sub _restore_system ( $self, $archive, $root, $preserve_etc ) {
    $self->_install_is_recover(1);
    my ($block_name) = split /\t+/,
      $self->_dropdown_block_devices->selected_text;
    my $block = "/dev/$block_name";
    $self->_install(
        complete_systemd => 0,
        container_block  => $block,
        prepare          => sub {
            excfailexit qw{sudo mount}, 'PARTUUID=' . $self->_root_uuid,
              '/mnt/gentoo';
            excfailexit qw{sudo mkdir -pv}, '/mnt/gentoo/boot/efi';
            excfailexit qw{sudo mount}, 'PARTUUID=' . $self->_efi_uuid,
              '/mnt/gentoo/boot/efi';
            excfailexit qw{sudo mkdir -pv}, '/mnt/gentoo/recovery';
            excfailexit qw{sudo mount}, 'PARTUUID=' . $self->_recovery_uuid,
              '/mnt/gentoo/recovery';
            system 'sudo mkdir /recovery';

            system qw{sudo mount},
              $self->_current_recovery_partition, '/recovery';

            die "Invalid archive\n" unless -f $archive;
            die "Invalid root\n"    unless -d $root;
            die "Refusing /\n" if $root eq '/';
            die "Archive inside root\n"
              if index( $archive, "$root/" ) == 0;

            my @keep = qw(
              passwd shadow group gshadow subuid subgid
              machine-id hostname hosts locale.conf locale.gen localtime adjtime
              fstab crypttab ssh udev/rules.d
              NetworkManager/system-connections systemd sudoers.d env.d
            );

            my $sudo = sub (@cmd) {
                system( 'sudo', @cmd ) == 0
                  or die "sudo @cmd failed\n";
            };

            $sudo->( 'tar', '-tf', $archive );

            my $old_etc_name = 'etc.old.' . int( rand(1000000000) );
            my $old          = "$root/$old_etc_name";

            eval { $sudo->( 'cp', '-a', '--', "$root/etc", $old ); };

            $sudo->(
                'find',      $root,   '-mindepth', 1,
                '-maxdepth', 1,       '!',         '-name',
                'boot',      '!',     '-name',     'grub_hash',
                '!',         '-name', 'recovery',  '!',
                '-name',     'home',  '!',         '-name',
                'etc.old*',  '-exec', 'rm',        '-rf',
                '--',        '{}',    '+'
            );

            $sudo->(
                'tar',                         '-xpf',
                $archive,                      '-C',
                $root,                         '--numeric-owner',
                '--xattrs-include=*',          '--exclude=home',
                '--exclude=./home',            '--exclude=home/*',
                '--exclude=./home/*',          '--exclude=' . $old_etc_name,
                "--exclude=./$old_etc_name",   "--exclude=$old_etc_name/*",
                "--exclude=./$old_etc_name/*", '--exclude=grub_hash',
                '--exclude=./grub_hash',
            );

            if ($preserve_etc) {
                for my $file (@keep) {
                    my $src = "$old/$file";
                    my $dst = "$root/etc/$file";
                    next unless -e $src;
                    if ( -d $src ) {
                        $src .= '/';
                        $dst .= '/';
                    }

                    $sudo->(
                        'rsync', '-a', qw{--mkpath --numeric-ids},
                        '--',    $src, $dst
                    );
                }
            }
            excfailexit qw{sudo cp -Lv}, '/etc/resolv.conf', '/mnt/gentoo/etc/';
            excfailexit
              qw{sudo rsync -P -a -v /recovery/rootfs.squashfs /mnt/gentoo/recovery/};
        }
    );
}

sub _on_click_select_media($self) {
    my ($block_name) = split /\t+/,
      $self->_dropdown_block_devices->selected_text;
    my $block      = "/dev/$block_name";
    my $root_count = my ( $root_label, $root_uuid ) = split /\s+/,
      `lsblk -o PARTLABEL,PARTUUID $block | grep AlgaOSRoot`;
    my $efi_count = my ( $efi_label, $efi_uuid ) = split /\s+/,
      `lsblk -o PARTLABEL,PARTUUID $block | grep AlgaOSEFI`;
    my $recovery_count = my ( $recovery_label, $recovery_uuid ) = split /\s+/,
      `lsblk -o PARTLABEL,PARTUUID $block | grep AlgaOSRecovery`;
    if ( !scalar $root_count ) {
        $self->_scroll->set_child( $self->_create_real_install_grid );
        return;
    }
    $self->_recovery_uuid($recovery_uuid);
    $self->_root_uuid($root_uuid);
    $self->_efi_uuid($efi_uuid);
    $self->_scroll->set_child( $self->_create_recover_installation_grid );
}

sub _failed_install {
    my $self = shift;
    say 'Failure';
    $self->_scroll->set_child(
        $self->_create_install_grid(
"The @{[$self->_install_is_recover ? 'recovery' : 'installation']} failed"
        )
    );
}

sub _succesful_install {
    my $self = shift;
    say 'Success';
    $self->_scroll->set_child(
        $self->_create_install_grid(
"The @{[$self->_install_is_recover ? 'recovery' : 'installation']} went well reboot and unplug the booting media use it"
        )
    );
}

sub _install( $self, %args ) {
    my ( $prepare, $hostname, $username, $password, $timezone, $locale,
        $complete_systemd, $container_block )
      = @args{
        qw/prepare hostname username password timezone locale complete_systemd container_block/
      };
    if ( !defined $prepare || ref $prepare ne 'CODE' ) {
        die 'No prepare sub';
    }
    $self->_scroll->set_child(
        $self->_create_install_grid(
"The system is now being @{[$self->_install_is_recover ? 'recovered' : 'installed']}"
        )
    );
    my $pid = fork;
    if ( !$pid ) {
        local $SIG{INT} = sub {
            system 'sudo umount -R /mnt/gentoo';
            system 'sudo umount -R /recovery';
        };
        eval {
            $prepare->();
            excfailexit qw{sudo perl}, @perl_args_chroot,
              qw{-MAlgaOS::Installer::GUI -e AlgaOS::Installer::GUI::chroot_install_commands(@ARGV)},
              $hostname, $username, $password, $timezone, $locale,
              $container_block, $complete_systemd;

            system 'sudo umount -R /mnt/gentoo';
            system 'sudo umount -R /recovery';
        };
        if ($@) {
            warn $@;
            exit 1;
        }
        say "Finish $$";
        exit 0;
    }
    $self->app->timeout_add(
        1000,
        sub {
            my $waitpid_result = waitpid( $pid, WNOHANG );
            if ( $waitpid_result == -1 ) {
                $self->_failed_install;
                return 0;
            }
            if ( $waitpid_result == 0 ) {
                return 1;
            }
            if ( $waitpid_result == $pid ) {
                if ( $? != 0 ) {
                    $self->_failed_install;
                    return 0;
                }
                $self->_succesful_install;
                return 0;
            }
            return 0;
        }
    );
}

sub chroot_install_commands {
    my ( $hostname, $username, $password, $timezone, $locale, $block_devices,
        $complete_systemd )
      = @ARGV;
    system qw{mount -t proc proc /mnt/gentoo/proc};
    system qw{mount --rbind /sys/ /mnt/gentoo/sys};
    system qw{mount --rbind /dev/ /mnt/gentoo/dev};
    system qw{mount --rbind /run/ /mnt/gentoo/run};
    system qw{mount --make-rslave /mnt/gentoo/proc};
    system qw{mount --make-rslave /mnt/gentoo/sys};
    system qw{mount --make-rslave /mnt/gentoo/dev};
    system qw{mount --make-rslave /mnt/gentoo/run};
    my $devices = `lsblk -o PARTLABEL,PARTUUID $block_devices`;
    chroot '/mnt/gentoo';
    chdir '/';
    open my $fh, '>', '/etc/hostname';
    say $fh "$hostname";
    close $fh;
    my @devices = split /\n/, $devices;
    shift @devices;
    @devices = grep { !/^\s*$/ } @devices;
    my %devices = map { ( split /\s+/, $_ ) } @devices;
    open $fh, '>', '/etc/fstab';
    say $fh <<"EOF";
PARTUUID=$devices{AlgaOSEFI}		/boot/efi		vfat		defaults        1 2
PARTUUID=$devices{AlgaOSRoot}		/		        ext4		defaults		0 1
PARTUUID=$devices{AlgaOSRecovery}   	/recovery 		ext4		defaults		0 1
EOF
    close $fh;

    if ($complete_systemd) {
        excfailexit qw{systemd-machine-id-setup};
        excfailexit qw{systemctl preset-all};
    }
    else {
        excfailexit qw{systemctl preset-all --preset-mode=enable-only};
    }
    excfailexit qw{systemctl enable gdm};
    excfailexit qw{systemctl enable NetworkManager};
    excfailexit qw{systemctl enable systemd-resolved};
    excfailexit qw{systemctl enable cronie};
    excfailexit qw{systemctl enable bluetooth};
    excfailexit qw{systemctl enable chronyd};
    excfailexit
      qw{systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service};

    if ($timezone) {
        excfailexit qw{ln -svf}, "../usr/share/zoneinfo/$timezone",
          '/etc/localtime';
    }
    if ($locale) {
        excfailexit qw{eselect locale set}, $locale;
    }
    if ($username) {
        system qw{useradd -m}, $username, qw{-s /bin/bash};
        system qw{gpasswd -a}, $username, qw{plugdev};
    }
    if ( $username && $password ) {
        open $fh, '|-', qw{passwd --stdin}, $username;
        say $fh $password;
        close $fh;
    }

    if ( $? != 0 ) {
        excfailexit "forcing-a-fail-because-passwd-failed-and-iam-lazy";
    }
    my $sudoers_dir = '/etc/sudoers.d';
    excfailexit qw{mkdir -pv}, $sudoers_dir;
    if ($username) {
        open $fh, '>', "$sudoers_dir/algaos";
        say $fh "$username ALL=(ALL) NOPASSWD: ALL";
        close $fh;
    }
    excfailexit qw{emerge --sync};
    excfailexit qw{plymouth-set-default-theme -R colorful_loop};
    excfailexit qw{rm -frv /var/db/repos/algaos/};
    $ENV{HOME}          = '/home/test';
    $ENV{USER}          = 'test';
    $ENV{LOGNAME}       = 'test';
    $ENV{XDG_DATA_HOME} = '/home/test/.local/share';
    $ENV{XDG_DATA_DIRS} =
'/home/test/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share';

    if ($username) {
        excfailexit qw{sudo -u}, $username, qw{dbus-run-session -- bash -c},
"flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo";
        excfailexit qw{sudo -u}, $username, qw{dbus-run-session -- bash -c},
          "flatpak --user install --noninteractive com.valvesoftware.Steam";
        excfailexit qw{sudo -u}, $username, qw{dbus-run-session -- bash -c},
          "flatpak --user install --noninteractive com.usebottles.bottles";
    }
    excfailexit(
        qw{update-grub},
        (
            defined $password ? ( '--new-pass', $password )
            : ()
        ),
        qw{--target-device},
        $block_devices,
        (
            defined $username ? ( '--user', $username )
            : ()
        )
    );
    exit 0;
}

sub activate($self) {
    my $const                     = $self->const;
    my $win                       = Gtk::ApplicationWindow->new( $self->app );
    my $start_installation_button = Gtk::Button->new("Install in this disk");
    $self->_start_installation_button($start_installation_button);
    $win->set_title("Install AlgaOS");
    my $display  = $win->get_display;
    my $provider = Gtk::CssProvider->new;
    $provider->load_from_path( $dist_dir_files . '/style.css' );
    $display->add_css_provider( $provider,
        $const->GTK_STYLE_PROVIDER_PRIORITY_APPLICATION );
    my $width  = 800;
    my $height = ( 1080 * 800 ) / 1920;
    $win->set_default_size( $width, $height );
    $win->set_resizable(0);
    $self->win($win);
    my $overlay = Gtk::Overlay->new;
    my $file    = Gio::File->new( $dist_dir_files . '/beach0.jpg' );
    my $texture = Gdk::Texture->new($file);
    my $picture = Gtk::Picture->new($texture);
    $overlay->set_child($picture);
    my $hostname_entry = Gtk::Entry->new;
    $self->_hostname_entry($hostname_entry);
    my $username_entry = Gtk::Entry->new;
    $self->_username_entry($username_entry);
    my $password_entry = Gtk::Entry->new;
    $self->_password_entry($password_entry);
    my $scroll = Gtk::ScrolledWindow->new;
    $scroll->set_child( $self->_internet_wall );
    $self->_scroll($scroll);
    $overlay->add_overlay($scroll);
    $win->set_child($overlay);
    $win->present;
}

sub _internet_wall($self) {
    my $grid = Gtk::Grid->new;
    $self->call_and_increment_grid_row(
        sub {
            my $label = Gtk::Label->new('Install AlgaOS');
            $label->add_css_class('title-1');
            $grid->attach( $label, 0, $self->_grid_row, 3, 1 );
        }
    );
    $self->call_and_increment_grid_row(
        sub {
            $grid->attach(
                Gtk::Label->new(
'To install or restore AlgaOS connect to internet, sorry for the inconvenience'
                ),
                0,
                $self->_grid_row,
                1, 1
            );
        }
    );
    my $first_try = 1;
    $self->app->timeout_add(
        1000,
        sub {
            if ($first_try) {
                if ( !system qw{sudo mount PARTLABEL=AlgaOSRoot /mnt/gentoo} ) {
                    system
                      qw{sudo rsync -a -P /mnt/gentoo/etc/NetworkManager/system-connections/ /etc/NetworkManager/system-connections/};
                    system qw{sudo systemctl restart NetworkManager};
                    system qw{sudo systemctl restart systemd-resolved};
                    system qw{sudo umount -R /mnt/gentoo};
                }
            }
            $first_try = 0;
            if ( !system qw{ping -c1 google.com} ) {
                $self->_scroll->set_child( $self->_create_main_grid );
                return 0;
            }
            return 1;
        }
    );
    my $const = $self->const;
    $grid->add_css_class('transparent_background');
    $grid->set_valign( $const->GTK_ALIGN_CENTER );
    $grid->set_halign( $const->GTK_ALIGN_CENTER );
    return $grid;
}

sub run($self) {
    system qw{sudo umount -R /mnt/gentoo};
    system 'sudo umount -R /recovery';
    $self->app->connect(
        'activate' => sub {
            $self->activate;
        }
    );

    $self->app->run(@ARGV);
}
1;
