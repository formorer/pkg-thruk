package Thruk::Controller::conf;

use strict;
use warnings;
use Thruk 1.1.5;
use Thruk::Utils::Menu;
use Thruk::Utils::Conf;
use Thruk::Utils::Conf::Defaults;
use Monitoring::Config;
use Carp;
use File::Copy;
use JSON::XS;
use parent 'Catalyst::Controller';
use Storable qw/dclone/;
use Data::Dumper;
use File::Slurp;
use Socket;
use Encode qw(decode_utf8);
use Config::General qw(ParseConfig);
use Digest::MD5 qw(md5_hex);

=head1 NAME

Thruk::Controller::conf - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

######################################
# add new menu item, but only if user has all of the
# requested roles
Thruk::Utils::Menu::insert_item('System', {
                                    'href'  => '/thruk/cgi-bin/conf.cgi',
                                    'name'  => 'Config Tool',
                                    'roles' => [qw/authorized_for_configuration_information
                                                   authorized_for_system_commands/],
                         });

# enable config features if this plugin is loaded
Thruk->config->{'use_feature_configtool'} = 1;

######################################

=head2 conf_cgi

page: /thruk/cgi-bin/conf.cgi

=cut
sub conf_cgi : Regex('thruk\/cgi\-bin\/conf\.cgi') {
    my ( $self, $c ) = @_;
    return if defined $c->{'canceled'};
    return $c->detach('/conf/index');
}


##########################################################

=head2 index

=cut
sub index :Path :Args(0) :MyAction('AddSafeDefaults') {
    my ( $self, $c ) = @_;

    # check permissions
    unless( $c->check_user_roles( "authorized_for_configuration_information")
        and $c->check_user_roles( "authorized_for_system_commands")) {
        if(    !defined $c->{'db'}
            or !defined $c->{'db'}->{'backends'}
            or ref $c->{'db'}->{'backends'} ne 'ARRAY'
            or scalar @{$c->{'db'}->{'backends'}} == 0 ) {
            # no backends configured or thruk config not possible
            if($c->config->{'Thruk::Plugin::ConfigTool'}->{'thruk'}) {
                return $c->detach("/error/index/14");
            }
        }
        # no permissions at all
        return $c->detach('/error/index/8');
    }

    $c->stash->{'no_auto_reload'}      = 1;
    $c->stash->{title}                 = 'Config Tool';
    $c->stash->{page}                  = 'config';
    $c->stash->{template}              = 'conf.tt';
    $c->stash->{subtitle}              = 'Config Tool';
    $c->stash->{infoBoxTitle}          = 'Config Tool';

    Thruk::Utils::ssi_include($c);

    # check if we have at least one file configured
    if(   !defined $c->config->{'Thruk::Plugin::ConfigTool'}
       or ref($c->config->{'Thruk::Plugin::ConfigTool'}) ne 'HASH'
       or scalar keys %{$c->config->{'Thruk::Plugin::ConfigTool'}} == 0
    ) {
        Thruk::Utils::set_message( $c, 'fail_message', 'Config Tool is disabled.<br>Please have a look at the <a href="'.$c->stash->{'url_prefix'}.'thruk/documentation.html#_component_thruk_plugin_configtool">config tool setup instructions</a>.' );
    }

    my $subcat                = $c->{'request'}->{'parameters'}->{'sub'} || '';
    my $action                = $c->{'request'}->{'parameters'}->{'action'}  || 'show';

    if(exists $c->{'request'}->{'parameters'}->{'edit'} and defined $c->{'request'}->{'parameters'}->{'host'}) {
        $subcat = 'objects';
    }

    $c->stash->{sub}          = $subcat;
    $c->stash->{action}       = $action;
    $c->stash->{conf_config}  = $c->config->{'Thruk::Plugin::ConfigTool'} || {};
    $c->stash->{has_obj_conf} = scalar keys %{Thruk::Utils::Conf::_get_backends_with_obj_config($c)};

    # set default
    $c->stash->{conf_config}->{'show_plugin_syntax_helper'} = 1 unless defined $c->stash->{conf_config}->{'show_plugin_syntax_helper'};

    if($action eq 'cgi_contacts') {
        return $self->_process_cgiusers_page($c);
    }
    elsif($action eq 'json') {
        return $self->_process_json_page($c);
    }

    # show settings page
    if($subcat eq 'cgi') {
        $self->_process_cgi_page($c);
    }
    elsif($subcat eq 'thruk') {
        $self->_process_thruk_page($c);
    }
    elsif($subcat eq 'users') {
        $self->_process_users_page($c);
    }
    elsif($subcat eq 'plugins') {
        $self->_process_plugins_page($c);
    }
    elsif($subcat eq 'backends') {
        $self->_process_backends_page($c);
    }
    elsif($subcat eq 'objects') {
        $c->stash->{'obj_model_changed'} = 1;
        $self->_process_objects_page($c);
        Thruk::Utils::Conf::store_model_retention($c) if $c->stash->{'obj_model_changed'};
        $c->stash->{'parse_errors'} = $c->{'obj_db'}->{'parse_errors'};
    }

    return 1;
}


##########################################################
# return json list for ajax search
sub _process_json_page {
    my( $self, $c ) = @_;

    return unless $self->_update_objects_config($c);

    my $type = $c->{'request'}->{'parameters'}->{'type'} || 'hosts';
    $type    =~ s/s$//gmxo;

    # name resolver
    if($type eq 'dig') {
        my $resolved = 'unknown';
        if(defined $c->{'request'}->{'parameters'}->{'host'} and $c->{'request'}->{'parameters'}->{'host'} ne '') {
            my @addresses = gethostbyname($c->{'request'}->{'parameters'}->{'host'});
            @addresses = map { inet_ntoa($_) } @addresses[4 .. $#addresses];
            if(scalar @addresses > 0) {
                $resolved = join(' ', @addresses);
            }
        }
        my $json            = { 'address' => $resolved };
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # icons?
    if($type eq 'icon') {
        my $objects = [];
        my $themes_dir = $c->config->{'themes_path'} || $c->config->{'home'}."/themes";
        my $dir        = $c->config->{'physical_logo_path'} || $themes_dir."/themes-available/Thruk/images/logos";
        $dir =~ s/\/$//gmx;
        my $files = _find_files($c, $dir, '\.(png|gif|jpg)$');
        for my $file (@{$files}) {
            $file =~ s/$dir\///gmx;
            push @{$objects}, $file." - ".$c->stash->{'logo_path_prefix'}.$file;
        }
        my $json            = [ { 'name' => $type.'s', 'data' => $objects } ];
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # macros
    if($type eq 'macro') {
        # common macros
        my $objects = [
            '$HOSTADDRESS$',
            '$HOSTALIAS$',
            '$HOSTNAME$',
            '$HOSTSTATE$',
            '$HOSTSTATEID$',
            '$HOSTATTEMPT$',
            '$HOSTOUTPUT$',
            '$LONGHOSTOUTPUT$',
            '$HOSTPERFDATA$',
            '$SERVICEDESC$',
            '$SERVICESTATE$',
            '$SERVICESTATEID$',
            '$SERVICESTATETYPE$',
            '$SERVICEATTEMPT$',
            '$SERVICEOUTPUT$',
            '$LONGSERVICEOUTPUT$',
            '$SERVICEPERFDATA$',
        ];
        if(defined $c->{'request'}->{'parameters'}->{'withargs'}) {
            push @{$objects}, ('$ARG1$', '$ARG2$', '$ARG3$', '$ARG4$', '$ARG5$');
        }
        if(defined $c->{'request'}->{'parameters'}->{'withuser'}) {
            my $user_macros = $c->{'db'}->_read_resource_file($c->{'obj_db'}->{'config'}->{'obj_resource_file'});
            push @{$objects}, keys %{$user_macros};
        }
        for my $type (qw/host service/) {
            for my $macro (keys %{$c->{'obj_db'}->{'macros'}->{$type}}) {
                push @{$objects}, '$_'.uc($type).uc(substr($macro, 1)).'$';
            }
        }
        @{$objects} = sort @{$objects};
        my $json            = [ { 'name' => 'macros', 'data' => $objects } ];
        if($c->stash->{conf_config}->{'show_plugin_syntax_helper'}) {
            if(defined $c->{'request'}->{'parameters'}->{'plugin'} and $c->{'request'}->{'parameters'}->{'plugin'} ne '') {
                my $help = $self->_get_plugin_help($c, $c->{'request'}->{'parameters'}->{'plugin'});
                my @options = $help =~ m/(\-[\w\d]|\-\-[\d\w\-_]+)[=|,|\s|\$]/gmx;
                push @{$json}, { 'name' => 'arguments', 'data' => Thruk::Utils::array_uniq(\@options) } if scalar @options > 0;
            }
        }
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # plugins
    if($type eq 'plugin') {
        my $plugins         = $self->_get_plugins($c);
        my $json            = [ { 'name' => 'plugins', 'data' => [ sort keys %{$plugins} ] } ];
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # plugin help
    if($type eq 'pluginhelp' and $c->stash->{conf_config}->{'show_plugin_syntax_helper'}) {
        my $help            = $self->_get_plugin_help($c, $c->{'request'}->{'parameters'}->{'plugin'});
        my $json            = [ { 'plugin_help' => $help } ];
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # plugin preview
    if($type eq 'pluginpreview' and $c->stash->{conf_config}->{'show_plugin_syntax_helper'}) {
        my $output          = $self->_get_plugin_preview($c,
                                                         $c->{'request'}->{'parameters'}->{'command'},
                                                         $c->{'request'}->{'parameters'}->{'args'},
                                                         $c->{'request'}->{'parameters'}->{'host'},
                                                         $c->{'request'}->{'parameters'}->{'service'},
                                                        );
        my $json            = [ { 'plugin_output' => $output } ];
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # command line
    if($type eq 'commanddetail') {
        my $name    = $c->{'request'}->{'parameters'}->{'command'};
        my $objects = $c->{'obj_db'}->get_objects_by_name('command', $name);
        my $json = [ { 'cmd_line' => '' } ];
        if(defined $objects->[0]) {
            $json = [ { 'cmd_line' => $objects->[0]->{'conf'}->{'command_line'} } ];
        }
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # servicemembers
    if($type eq 'servicemember') {
        my $members = [];
        my $objects = $c->{'obj_db'}->get_objects_by_type('host');
        for my $host (@{$objects}) {
            my $hostname = $host->get_name();
            my $services = $c->{'obj_db'}->get_services_for_host($host);
            for my $svc (keys %{$services->{'group'}}, keys %{$services->{'host'}}) {
                push @{$members}, $hostname.','.$svc;
            }
        }
        my $json = [{ 'name' => $type.'s',
                      'data' => [ sort @{Thruk::Utils::array_uniq($members)} ],
                   }];
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # objects attributes
    if($type eq 'attribute') {
        my $for  = $c->{'request'}->{'parameters'}->{'obj'};
        my $attr = $c->{'obj_db'}->get_default_keys($for, { no_alias => 1 });
        push @{$attr}, 'customvariable';
        my $json = [{ 'name' => $type.'s',
                      'data' => [ sort @{Thruk::Utils::array_uniq($attr)} ],
                   }];
        $c->stash->{'json'} = $json;
        $c->forward('Thruk::View::JSON');
        return;
    }

    # objects
    my $json;
    my $objects   = [];
    my $templates = [];
    my $filter    = $c->{'request'}->{'parameters'}->{'filter'};
    my $use_long  = $c->{'request'}->{'parameters'}->{'long'};
    if(defined $filter) {
        my $types   = {};
        my $objects = $c->{'obj_db'}->get_objects_by_type($type,$filter);
        for my $subtype (keys %{$objects}) {
            for my $name (keys %{$objects->{$subtype}}) {
                $types->{$subtype}->{$name} = 1 unless substr($name,0,1) eq '!';
            }
        }
        for my $typ (sort keys %{$types}) {
            push @{$json}, {
                  'name' => $self->_translate_type($typ)."s",
                  'data' => [ sort keys %{$types->{$typ}} ],
            };
        }
    } else {
        for my $dat (@{$c->{'obj_db'}->get_objects_by_type($type)}) {
            my $name = $use_long ? $dat->get_long_name() : $dat->get_name();
            if(defined $name) {
                push @{$objects}, $name
            } else {
                $c->log->warn("object without a name in ".$dat->{'file'}->{'path'}.":".$dat->{'line'}." -> ".Dumper($dat->{'conf'}));
            }
        }
        for my $dat (@{$c->{'obj_db'}->get_templates_by_type($type)}) {
            my $name = $dat->get_template_name();
            if(defined $name) {
                push @{$templates}, $name;
            } else {
                $c->log->warn("template without a name in ".$dat->{'file'}->{'path'}.":".$dat->{'line'}." -> ".Dumper($dat->{'conf'}));
            }
        }
        $json = [ { 'name' => $type.'s',
                    'data' => [ sort @{Thruk::Utils::array_uniq($objects)} ],
                  },
                  { 'name' => $type.' templates',
                    'data' => [ sort @{Thruk::Utils::array_uniq($templates)} ],
                  }
                ];
    }
    $c->stash->{'json'} = $json;
    $c->forward('Thruk::View::JSON');
    return;
}


##########################################################
# create the cgi.cfg config page
sub _process_cgiusers_page {
    my( $self, $c ) = @_;

    my $contacts        = Thruk::Utils::Conf::get_cgi_user_list($c);
    delete $contacts->{'*'}; # we dont need this user here
    my $data            = [ values %{$contacts} ];
    my $json            = [ { 'name' => "contacts", 'data' => $data } ];
    $c->stash->{'json'} = $json;
    $c->forward('Thruk::View::JSON');
    return;
}


##########################################################
# create the cgi.cfg config page
sub _process_cgi_page {
    my( $self, $c ) = @_;

    my $file     = $c->config->{'Thruk::Plugin::ConfigTool'}->{'cgi.cfg'};
    return unless defined $file;
    $c->stash->{'readonly'} = (-w $file) ? 0 : 1;

    # create a default config from the current used cgi.cfg
    if(!-e $file and $file ne $c->config->{'cgi.cfg_effective'}) {
        copy($c->config->{'cgi.cfg_effective'}, $file) or die('cannot copy '.$c->config->{'cgi.cfg_effective'}.' to '.$file.': '.$!);
    }

    my $defaults = Thruk::Utils::Conf::Defaults->get_cgi_cfg();

    # save changes
    if($c->stash->{action} eq 'store') {
        if($c->stash->{'readonly'}) {
            Thruk::Utils::set_message( $c, 'fail_message', 'file is readonly' );
            return $c->response->redirect('conf.cgi?sub=cgi');
        }

        my $data = Thruk::Utils::Conf::get_data_from_param($c->{'request'}->{'parameters'}, $defaults);
        # check for empty multi selects
        for my $key (keys %{$defaults}) {
            next if $key !~ m/^authorized_for_/mx;
            $data->{$key} = [] unless defined $data->{$key};
        }
        $self->_store_changes($c, $file, $data, $defaults);
        return $c->response->redirect('conf.cgi?sub=cgi');
    }

    my($content, $data, $md5) = Thruk::Utils::Conf::read_conf($file, $defaults);

    # get list of cgi users
    my $cgi_contacts = Thruk::Utils::Conf::get_cgi_user_list($c);

    for my $key (keys %{$data}) {
        next unless $key =~ m/^authorized_for_/mx;
        $data->{$key}->[2] = $cgi_contacts;
    }

    # get list of cgi users
    my $cgi_groups = Thruk::Utils::Conf::get_cgi_group_list($c);
    for my $key (keys %{$data}) {
        next unless $key =~ m/^authorized_contactgroup_for_/mx;
        $data->{$key}->[2] = $cgi_groups;
    }

    my $keys = [
        [ 'CGI Settings', [qw/
                        show_context_help
                        use_pending_states
                        refresh_rate
                        escape_html_tags
                        action_url_target
                        notes_url_target
                    /]
        ],
        [ 'Authorization', [qw/
                        use_authentication
                        use_ssl_authentication
                        default_user_name
                        lock_author_names
                        authorized_for_all_services
                        authorized_for_all_hosts
                        authorized_for_all_service_commands
                        authorized_for_all_host_commands
                        authorized_for_system_information
                        authorized_for_system_commands
                        authorized_for_configuration_information
                        authorized_for_read_only
                    /]
        ],
        [ 'Authorization Groups', [qw/
                      authorized_contactgroup_for_all_services
                      authorized_contactgroup_for_all_hosts
                      authorized_contactgroup_for_all_service_commands
                      authorized_contactgroup_for_all_host_commands
                      authorized_contactgroup_for_system_information
                      authorized_contactgroup_for_system_commands
                      authorized_contactgroup_for_configuration_information
                      authorized_contactgroup_for_read_only
                    /]
        ],
    ];

    $c->stash->{'keys'}     = $keys;
    $c->stash->{'data'}     = $data;
    $c->stash->{'md5'}      = $md5;
    $c->stash->{'subtitle'} = "CGI &amp; Access Configuration";
    $c->stash->{'template'} = 'conf_data.tt';

    return 1;
}

##########################################################
# create the thruk config page
sub _process_thruk_page {
    my( $self, $c ) = @_;

    my $file     = $c->config->{'Thruk::Plugin::ConfigTool'}->{'thruk'};
    return unless defined $file;
    my $defaults = Thruk::Utils::Conf::Defaults->get_thruk_cfg($c);
    $c->stash->{'readonly'} = (-w $file) ? 0 : 1;

    # save changes
    if($c->stash->{action} eq 'store') {
        if($c->stash->{'readonly'}) {
            Thruk::Utils::set_message( $c, 'fail_message', 'file is readonly' );
            return $c->response->redirect('conf.cgi?sub=thruk');
        }

        my $data = Thruk::Utils::Conf::get_data_from_param($c->{'request'}->{'parameters'}, $defaults);
        $self->_store_changes($c, $file, $data, $defaults, $c);
        return $c->response->redirect('conf.cgi?sub=thruk');
    }

    my($content, $data, $md5) = Thruk::Utils::Conf::read_conf($file, $defaults);

    my $keys = [
        [ 'General', [qw/
                        title_prefix
                        use_wait_feature
                        wait_timeout
                        use_frames
                        use_timezone
                        use_strict_host_authorization
                        show_long_plugin_output
                        info_popup_event_type
                        info_popup_options
                        resource_file
                        can_submit_commands
                     /]
        ],
        [ 'Paths', [qw/
                        tmp_path
                        ssi_path
                        plugin_path
                        user_template_path
                    /]
        ],
        [ 'Menu', [qw/
                        start_page
                        documentation_link
                        all_problems_link
                        allowed_frame_links
                    /]
        ],
        [ 'Display', [qw/
                        default_theme
                        strict_passive_mode
                        show_notification_number
                        show_backends_in_table
                        show_full_commandline
                        shown_inline_pnp
                        show_modified_attributes
                        statusmap_default_type
                        statusmap_default_groupby
                        datetime_format
                        datetime_format_today
                        datetime_format_long
                        datetime_format_log
                        datetime_format_trends
                        use_new_command_box
                        show_custom_vars
                    /]
        ],
        [ 'Search', [qw/
                        use_new_search
                        use_ajax_search
                        ajax_search_hosts
                        ajax_search_hostgroups
                        ajax_search_services
                        ajax_search_servicegroups
                        ajax_search_timeperiods
                    /]
        ],
        [ 'Paging', [qw/
                        use_pager
                        paging_steps
                        group_paging_overview
                        group_paging_summary
                        group_paging_grid
                    /]
        ],
    ];

    $c->stash->{'keys'}     = $keys;
    $c->stash->{'data'}     = $data;
    $c->stash->{'md5'}      = $md5;
    $c->stash->{'subtitle'} = "Thruk Configuration";
    $c->stash->{'template'} = 'conf_data.tt';

    return 1;
}

##########################################################
# create the users config page
sub _process_users_page {
    my( $self, $c ) = @_;

    my $file     = $c->config->{'Thruk::Plugin::ConfigTool'}->{'cgi.cfg'};
    return unless defined $file;
    my $defaults = Thruk::Utils::Conf::Defaults->get_cgi_cfg();
    $c->stash->{'readonly'} = (-w $file) ? 0 : 1;

    # save changes to user
    my $user = $c->{'request'}->{'parameters'}->{'data.username'} || '';
    if($user ne '' and defined $file and $c->stash->{action} eq 'store') {
        my $redirect = 'conf.cgi?action=change&sub=users&data.username='.$user;
        if($c->stash->{'readonly'}) {
            Thruk::Utils::set_message( $c, 'fail_message', 'file is readonly' );
            return $c->response->redirect($redirect);
        }
        my $msg      = $self->_update_password($c);
        if(defined $msg) {
            Thruk::Utils::set_message( $c, 'fail_message', $msg );
            return $c->response->redirect($redirect);
        }

        # save changes to cgi.cfg
        my($content, $data, $md5) = Thruk::Utils::Conf::read_conf($file, $defaults);
        my $new_data              = {};
        for my $key (keys %{$c->{'request'}->{'parameters'}}) {
            next unless $key =~ m/data\.authorized_for_/mx;
            $key =~ s/^data\.//gmx;
            my $users = {};
            for my $usr (@{$data->{$key}->[1]}) {
                $users->{$usr} = 1;
            }
            if($c->{'request'}->{'parameters'}->{'data.'.$key}) {
                $users->{$user} = 1;
            } else {
                delete $users->{$user};
            }
            @{$new_data->{$key}} = sort keys %{$users};
        }
        $self->_store_changes($c, $file, $new_data, $defaults);

        Thruk::Utils::set_message( $c, 'success_message', 'User saved successfully' );
        return $c->response->redirect($redirect);
    }

    $c->stash->{'show_user'}  = 0;
    $c->stash->{'user_name'}  = '';

    if($c->stash->{action} eq 'change' and $user ne '') {
        my($content, $data, $md5) = Thruk::Utils::Conf::read_conf($file, $defaults);
        my($name, $alias)         = split(/\ \-\ /mx,$user, 2);
        $c->stash->{'show_user'}  = 1;
        $c->stash->{'user_name'}  = $name;
        $c->stash->{'md5'}        = $md5;
        $c->stash->{'roles'}      = {};
        my $roles = [qw/authorized_for_all_services
                        authorized_for_all_hosts
                        authorized_for_all_service_commands
                        authorized_for_all_host_commands
                        authorized_for_system_information
                        authorized_for_system_commands
                        authorized_for_configuration_information
                    /];
        $c->stash->{'role_keys'}  = $roles;
        for my $role (@{$roles}) {
            $c->stash->{'roles'}->{$role} = 0;
            for my $tst (@{$data->{$role}->[1]}) {
                $c->stash->{'roles'}->{$role}++ if $tst eq $name;
            }
        }

        $c->stash->{'has_htpasswd_entry'} = 0;
        if(defined $c->config->{'Thruk::Plugin::ConfigTool'}->{'htpasswd'}) {
            my $htpasswd = Thruk::Utils::Conf::read_htpasswd($c->config->{'Thruk::Plugin::ConfigTool'}->{'htpasswd'});
            $c->stash->{'has_htpasswd_entry'} = 1 if defined $htpasswd->{$name};
        }

        $c->stash->{'has_contact'} = 0;
        my $contacts = $c->{'db'}->get_contacts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'contact' ), name => $name ] );
        if(defined $contacts and scalar @{$contacts} >= 1) {
            $c->stash->{'has_contact'} = 1;
        }

    }

    $c->stash->{'subtitle'} = "User Configuration";
    $c->stash->{'template'} = 'conf_data_users.tt';

    return 1;
}

##########################################################
# create the plugins config page
sub _process_plugins_page {
    my( $self, $c ) = @_;

    my $project_root         = $c->config->{home};
    my $plugin_dir           = $c->config->{'plugin_path'} || $project_root."/plugins";
    my $plugin_enabled_dir   = $plugin_dir.'/plugins-enabled';
    my $plugin_available_dir = $project_root.'/plugins/plugins-available';

    $c->stash->{'readonly'}  = 0;
    if(! -d $plugin_enabled_dir or ! -w $plugin_enabled_dir ) {
        $c->stash->{'readonly'}  = 1;
    }

    if($c->stash->{action} eq 'preview') {
        my $pic = $c->{'request'}->{'parameters'}->{'pic'} || die("missing pic");
        if($pic !~ m/^[a-zA-Z_\ ]+$/gmx) {
            die("unknown pic: ".$pic);
        }
        my $path = $plugin_available_dir.'/'.$pic.'/preview.png';
        $c->res->content_type('images/png');
        $c->stash->{'text'} = "";
        if(-e $path) {
            $c->stash->{'text'} = read_file($path);
        }
        $c->stash->{'template'} = 'passthrough.tt';
        return 1;
    }
    elsif($c->stash->{action} eq 'save') {
        if(! -d $plugin_enabled_dir or ! -w $plugin_enabled_dir ) {
            Thruk::Utils::set_message( $c, 'fail_message', 'Make sure plugins folder ('.$plugin_enabled_dir.') is writeable: '.$! );
        }
        else {
            for my $addon (glob($plugin_available_dir.'/*/')) {
                my($addon_name, $dir) = _nice_addon_name($addon);
                if(!defined $c->{'request'}->{'parameters'}->{'plugin.'.$dir} or $c->{'request'}->{'parameters'}->{'plugin.'.$dir} == 0) {
                    unlink($plugin_enabled_dir.'/'.$dir);
                }
                if(defined $c->{'request'}->{'parameters'}->{'plugin.'.$dir} and $c->{'request'}->{'parameters'}->{'plugin.'.$dir} == 1) {
                    if(!-e $plugin_enabled_dir.'/'.$dir) {
                        symlink($plugin_available_dir.'/'.$dir,
                                $plugin_enabled_dir.'/'.$dir)
                            or die("cannot create ".$plugin_enabled_dir.'/'.$dir." : ".$!);
                    }
                }
            }
            Thruk::Utils::set_message( $c, 'success_message', 'Plugins changed successfully.' );
            return Thruk::Utils::restart_later($c, $c->stash->{url_prefix}.'thruk/cgi-bin/conf.cgi?sub=plugins');
        }
    }

    my $plugins = {};
    for my $addon (glob($plugin_available_dir.'/*/')) {
        my($addon_name, $dir) = _nice_addon_name($addon);
        $plugins->{$addon_name} = { enabled => 0, dir => $dir, description => '(no description available.)', url => '' };
        if(-e $plugin_available_dir.'/'.$dir.'/description.txt') {
            my $description = read_file($plugin_available_dir.'/'.$dir.'/description.txt');
            my $url         = "";
            if($description =~ s/^Url:\s*(.*)$//gmx) { $url = $1; }
            $plugins->{$addon_name}->{'description'} = $description;
            $plugins->{$addon_name}->{'url'}         = $url;
        }
    }
    for my $addon (glob($plugin_enabled_dir.'/*/')) {
        my($addon_name, $dir) = _nice_addon_name($addon);
        $plugins->{$addon_name}->{'enabled'} = 1;
    }

    $c->stash->{'plugins'}  = $plugins;
    $c->stash->{'subtitle'} = "Thruk Addons &amp; Plugin Manager";
    $c->stash->{'template'} = 'conf_plugins.tt';

    return 1;
}

##########################################################
# create the backends config page
sub _process_backends_page {
    my( $self, $c ) = @_;

    my $file = $c->config->{'Thruk::Plugin::ConfigTool'}->{'thruk'};
    return unless $file;
    $c->stash->{'readonly'} = (-w $file) ? 0 : 1;

    if($c->stash->{action} eq 'save') {
        if($c->stash->{'readonly'}) {
            Thruk::Utils::set_message( $c, 'fail_message', 'file is readonly' );
            return $c->response->redirect('conf.cgi?sub=backends');
        }

        my $x=0;
        my $backends = [];
        my $new = 0;
        while(defined $c->request->parameters->{'name'.$x}) {
            my $backend = {
                'name'   => $c->request->parameters->{'name'.$x},
                'type'   => $c->request->parameters->{'type'.$x},
                'id'     => $c->request->parameters->{'id'.$x},
                'hidden' => defined $c->request->parameters->{'hidden'.$x} ? $c->request->parameters->{'hidden'.$x} : 0,
                'options' => {
                    'peer'   => $c->request->parameters->{'peer'.$x},
                },
            };
            $x++;
            next unless defined $backend->{'name'};
            next unless $backend->{'name'} ne '';
            next unless defined $backend->{'options'}->{'peer'};
            next unless $backend->{'options'}->{'peer'} ne '';
            delete $backend->{'id'} if $backend->{'id'} eq '';

            # add values from existing backend config
            if(defined $backend->{'id'}) {
                my $peer = $c->{'db'}->get_peer_by_key($backend->{'id'});
                $backend->{'options'}->{'resource_file'} = $peer->{'resource_file'} if defined $peer->{'resource_file'};
                $backend->{'groups'}     = $peer->{'groups'}     if defined $peer->{'groups'};
                $backend->{'configtool'} = $peer->{'configtool'} if defined $peer->{'configtool'};
            }
            $new = 1 if $x == 1;
            push @{$backends}, $backend;
        }
        # put new one at the end
        if($new) { push(@{$backends}, shift(@{$backends})) }
        my $string    = Thruk::Utils::Conf::get_component_as_string($backends);
        Thruk::Utils::Conf::replace_block($file, $string, '<Component\s+Thruk::Backend>', '<\/Component>');
        Thruk::Utils::set_message( $c, 'success_message', 'Backends changed successfully.' );
        return Thruk::Utils::restart_later($c, $c->stash->{url_prefix}.'thruk/cgi-bin/conf.cgi?sub=backends');
    }
    if($c->stash->{action} eq 'check_con') {
        my $peer = $c->request->parameters->{'con'};
        my $type = $c->request->parameters->{'type'};
        my @test;
        eval {
            my $con = Thruk::Backend::Manager->create_backend('test', $type, { peer => $peer});
            @test   = $con->get_processinfo();
        };
        if(scalar @test == 2 and ref $test[0] eq 'HASH' and scalar keys %{$test[0]} == 1 and scalar keys %{$test[0]->{(keys %{$test[0]})[0]}} > 0) {
            $c->stash->{'json'} = { ok => 1 };
        } else {
            my $error = $@;
            $error =~ s/\s+at\s\/.*//gmx;
            $error = 'got no valid result' if $error eq '';
            $c->stash->{'json'} = { ok => 0, error => $error };
        }
        return $c->forward('Thruk::View::JSON');
    }

    my $backends = [];
    my %conf;
    if(-f $file) {
        %conf = ParseConfig($file);
    } else {
        $file =~ s/thruk_local\.conf/thruk.conf/mx;
        %conf = ParseConfig($file) if -f $file;
    }

    if(keys %conf > 0) {
        if(defined $conf{'Component'}->{'Thruk::Backend'}->{'peer'}) {
            if(ref $conf{'Component'}->{'Thruk::Backend'}->{'peer'} eq 'ARRAY') {
                $backends = $conf{'Component'}->{'Thruk::Backend'}->{'peer'};
            } else {
                push @{$backends}, $conf{'Component'}->{'Thruk::Backend'}->{'peer'};
            }
        }
    }
    # set ids
    for my $b (@{$backends}) {
        $b->{'key'}    = substr(md5_hex($b->{'options'}->{'peer'}." ".$b->{'name'}), 0, 5) unless defined $b->{'key'};
        $b->{'addr'}   = $b->{'options'}->{'peer'};
        $b->{'hidden'} = 0 unless defined $b->{'hidden'};
    }
    $c->stash->{'sites'}    = $backends;
    $c->stash->{'subtitle'} = "Thruk Backends Manager";
    $c->stash->{'template'} = 'conf_backends.tt';

    return 1;
}

##########################################################
# create the objects config page
sub _process_objects_page {
    my( $self, $c ) = @_;

    $c->stash->{'last_changed'} = 0;
    $c->stash->{'needs_commit'} = 0;

    return unless $self->_update_objects_config($c);

    _check_external_reload($c);

    $c->stash->{'subtitle'}        = "Object Configuration";
    $c->stash->{'template'}        = 'conf_objects.tt';
    $c->stash->{'file_link'}       = "";
    $c->stash->{'coretype'}        = $c->{'obj_db'}->{'coretype'};

    # apply changes?
    if(defined $c->{'request'}->{'parameters'}->{'apply'}) {
        return $self->_apply_config_changes($c);
    }

    # tools menu
    if(defined $c->{'request'}->{'parameters'}->{'tools'}) {
        return $self->_process_tools_page($c);
    }

    # get object from params
    my $obj = $self->_get_context_object($c);
    if(defined $obj) {

        # revert all changes from one file
        if($c->stash->{action} eq 'revert') {
            return if $self->_object_revert($c, $obj);
        }

        # save this object
        elsif($c->stash->{action} eq 'store') {
            return if $self->_object_save($c, $obj);
        }

        # delete this object
        elsif($c->stash->{action} eq 'delete') {
            return if $self->_object_delete($c, $obj);
        }

        # move objects
        elsif(   $c->stash->{action} eq 'move'
              or $c->stash->{action} eq 'movefile') {
            return if $self->_object_move($c, $obj);
        }

        # clone this object
        elsif($c->stash->{action} eq 'clone') {
            $obj = $self->_object_clone($c, $obj);
        }

        # list services for host
        elsif($c->stash->{action} eq 'listservices' and $obj->get_type() eq 'host') {
            $self->_host_list_services($c, $obj);
        }

        # list references
        elsif($c->stash->{action} eq 'listref') {
            $self->_list_references($c, $obj);
        }
    }

    # create new object
    if($c->stash->{action} eq 'new') {
        $obj = $self->_object_new($c);
    }

    # browse files
    elsif($c->stash->{action} eq 'browser') {
        return if $self->_file_browser($c);
    }

    # file editor
    elsif($c->stash->{action} eq 'editor') {
        return if $self->_file_editor($c);
    }

    # save changed files from editor
    elsif($c->stash->{action} eq 'savefile') {
        return if $self->_file_save($c);
    }

    # delete files/folders from browser
    elsif($c->stash->{action} eq 'deletefiles') {
        return if $self->_file_delete($c);
    }

    # undelete files/folders from browser
    elsif($c->stash->{action} eq 'undeletefiles') {
        return if $self->_file_undelete($c);
    }

    # set type and name of object
    if(defined $obj) {
        $c->stash->{'show_object'}    = 1;
        $c->stash->{'object'}         = $obj;
        $c->stash->{'data_name'}      = $obj->get_name();
        $c->stash->{'type'}           = $obj->get_type();
        $c->stash->{'used_templates'} = $obj->get_used_templates($c->{'obj_db'});
        $c->stash->{'file_link'}      = $obj->{'file'}->{'path'} if defined $obj->{'file'};
    }

    # set default type for start page
    if($c->stash->{action} eq 'show' and $c->stash->{type} eq '') {
        $c->stash->{type} = 'host';
    }

    $c->stash->{'needs_commit'}      = $c->{'obj_db'}->{'needs_commit'};
    $c->stash->{'last_changed'}      = $c->{'obj_db'}->{'last_changed'};
    $c->stash->{'obj_model_changed'} = 0 unless $c->{'request'}->{'parameters'}->{'refresh'};
    return 1;
}


##########################################################
# apply config changes
sub _apply_config_changes {
    my ( $self, $c ) = @_;

    $c->stash->{'subtitle'}      = "Apply Config Changes";
    $c->stash->{'template'}      = 'conf_objects_apply.tt';
    $c->stash->{'output'}        = '';
    $c->stash->{'changed_files'} = $c->{'obj_db'}->get_changed_files();

    # get diff of changed files
    if(defined $c->{'request'}->{'parameters'}->{'diff'}) {
        for my $file (@{$c->stash->{'changed_files'}}) {
            $c->stash->{'output'} .= "<hr><pre>\n";
            $c->stash->{'output'} .= Thruk::Utils::Filter::escape_html($file->diff());
            $c->stash->{'output'} .= "</pre><br>\n";
        }
    }

    # config check
    elsif(defined $c->{'request'}->{'parameters'}->{'check'}) {
        if(defined $c->stash->{'peer_conftool'}->{'obj_check_cmd'}) {
            $c->stash->{'parse_errors'} = $c->{'obj_db'}->{'parse_errors'};
            Thruk::Utils::External::perl($c, { expr    => 'Thruk::Controller::conf::_config_check($c)',
                                               message => 'please stand by while configuration is beeing checked...'
                                              }
                                        );
            return;
        } else {
            Thruk::Utils::set_message( $c, 'fail_message', "please set 'obj_check_cmd' in your thruk_local.conf" );
        }
    }

    # config reload
    elsif(defined $c->{'request'}->{'parameters'}->{'reload'}) {
        if(defined $c->stash->{'peer_conftool'}->{'obj_reload_cmd'}) {
            $c->stash->{'parse_errors'} = $c->{'obj_db'}->{'parse_errors'};
            Thruk::Utils::External::perl($c, { expr    => 'Thruk::Controller::conf::_config_reload($c)',
                                               message => 'please stand by while configuration is beeing reloaded...'
                                              }
                                        );
            return;
        } else {
            Thruk::Utils::set_message( $c, 'fail_message', "please set 'obj_reload_cmd' in your thruk_local.conf" );
        }
    }

    # save changes to file
    elsif(defined $c->{'request'}->{'parameters'}->{'save'}) {
        if($c->{'obj_db'}->commit()) {
            Thruk::Utils::set_message( $c, 'success_message', 'Changes saved to disk successfully' );
        }
        return $c->response->redirect('conf.cgi?sub=objects&apply=yes');
    }

    # make nicer output
    if(defined $c->{'request'}->{'parameters'}->{'diff'}) {
        $c->{'stash'}->{'output'} =~ s/^\-\-\-(.*)$/<font color="#0776E8"><b>---$1<\/b><\/font>/gmx;
        $c->{'stash'}->{'output'} =~ s/^\+\+\+(.*)$//gmx;
        $c->{'stash'}->{'output'} =~ s/^\@\@(.*)$/<font color="#0776E8"><b>\@\@$1<\/b><\/font>/gmx;
        $c->{'stash'}->{'output'} =~ s/^\-(.*)$/<font color="red">-$1<\/font>/gmx;
        $c->{'stash'}->{'output'} =~ s/^\+(.*)$/<font color="green">+$1<\/font>/gmx;
    }

    if($c->{'request'}->{'parameters'}->{'refresh'}) {
        Thruk::Utils::set_message( $c, 'success_message', 'Changes have been discarded' );
        return $c->response->redirect('conf.cgi?sub=objects&apply=yes');
    }
    $c->stash->{'obj_model_changed'} = 0 unless $c->{'request'}->{'parameters'}->{'refresh'};
    $c->stash->{'needs_commit'}      = $c->{'obj_db'}->{'needs_commit'};
    $c->stash->{'last_changed'}      = $c->{'obj_db'}->{'last_changed'};
    $c->stash->{'files'}             = $c->{'obj_db'}->get_files();
    return;
}

##########################################################
# show tools page
sub _process_tools_page {
    my ( $self, $c ) = @_;

    $c->stash->{'subtitle'}      = 'Config Tools';
    $c->stash->{'template'}      = 'conf_objects_tools.tt';
    $c->stash->{'output'}        = '';
    $c->stash->{'action'}        = 'tools';
    $c->stash->{'warnings'}      = [];

    my $tool   = $c->{'request'}->{'parameters'}->{'tools'} || 'start';

    if($tool eq 'check_object_references') {
        my $warnings = [ @{$c->{'obj_db'}->_check_references()}, @{$c->{'obj_db'}->_check_orphaned_objects()} ];
        @{$warnings} = sort @{$warnings};
        $c->stash->{'warnings'} = $warnings;
    }

    $c->stash->{'tool'} = $tool;
    return;
}

##########################################################
# update a users password
sub _update_password {
    my ( $self, $c ) = @_;

    my $user = $c->{'request'}->{'parameters'}->{'data.username'};
    my $send = $c->{'request'}->{'parameters'}->{'send'} || 'save';
    if(defined $c->config->{'Thruk::Plugin::ConfigTool'}->{'htpasswd'}) {
        # remove password?
        if($send eq 'remove password') {
            my $cmd = sprintf("%s -D %s '%s' 2>&1",
                                 '$(which htpasswd2 2>/dev/null || which htpasswd 2>/dev/null)',
                                 $c->config->{'Thruk::Plugin::ConfigTool'}->{'htpasswd'},
                                 $user
                             );
            if($self->_cmd($c, $cmd)) {
                $c->log->info("removed password for ".$user);
                return;
            }
            return( 'failed to remove password, check the logfile!' );
        }

        # change password?
        my $pass1 = $c->{'request'}->{'parameters'}->{'data.password'}  || '';
        my $pass2 = $c->{'request'}->{'parameters'}->{'data.password2'} || '';
        if($pass1 ne '') {
            if($pass1 eq $pass2) {
                $pass1 =~ s/'/\'/gmx;
                $user  =~ s/'/\'/gmx;
                my $create = -s $c->config->{'Thruk::Plugin::ConfigTool'}->{'htpasswd'} ? '' : '-c ';
                my $cmd    = sprintf("%s -b %s '%s' '%s' '%s' 2>&1",
                                        '$(which htpasswd2 2>/dev/null || which htpasswd 2>/dev/null)',
                                        $create,
                                        $c->config->{'Thruk::Plugin::ConfigTool'}->{'htpasswd'},
                                        $user,
                                        $pass1
                                    );
                if($self->_cmd($c, $cmd)) {
                    $c->log->info("changed password for ".$user);
                    return;
                }
                return( 'failed to update password, check the logfile!' );
            } else {
                return( 'Passwords do not match' );
            }
        }
    }
    return;
}


##########################################################
# store changes to a file
sub _store_changes {
    my ( $self, $c, $file, $data, $defaults, $update_in_conf ) = @_;
    my $old_md5 = $c->{'request'}->{'parameters'}->{'md5'} || '';
    $c->log->debug("saving config changes to ".$file);
    my $res     = Thruk::Utils::Conf::update_conf($file, $data, $old_md5, $defaults, $update_in_conf);
    if(defined $res) {
        Thruk::Utils::set_message( $c, 'fail_message', $res );
    } else {
        Thruk::Utils::set_message( $c, 'success_message', 'Saved successfully' );
    }
    return;
}

##########################################################
# execute cmd
sub _cmd {
    my ( $self, $c, $cmd ) = @_;

    local $SIG{CHLD}='';
    local $ENV{REMOTE_USER}=$c->stash->{'remote_user'};
    $c->log->debug( "running cmd: ". $cmd );
    my $rc = $?;
    my $output = `$cmd 2>&1`;
    if($? == -1) {
        $output .= "[".$!."]";
    } else {
        $rc = $?>>8;
    }

    $c->{'stash'}->{'output'} = decode_utf8($output);
    $c->log->debug( "rc:     ". $rc );
    $c->log->debug( "output: ". $output );
    if($rc != 0) {
        return 0;
    }
    return 1;
}


##########################################################
sub _update_objects_config {
    my ( $self, $c ) = @_;
    return Thruk::Utils::Conf::set_object_model($c);
}


##########################################################
sub _find_files {
    my $c     = shift;
    my $dir   = shift;
    my $types = shift;
    my $files = $c->{'obj_db'}->_get_files_for_folder($dir, $types);
    return $files;
}

##########################################################
sub _get_context_object {
    my $self  = shift;
    my $c     = shift;
    my $obj;

    $c->stash->{'type'}          = $c->{'request'}->{'parameters'}->{'type'}       || '';
    $c->stash->{'subcat'}        = $c->{'request'}->{'parameters'}->{'subcat'}     || 'config';
    $c->stash->{'data_name'}     = $c->{'request'}->{'parameters'}->{'data.name'}  || '';
    $c->stash->{'data_name2'}    = $c->{'request'}->{'parameters'}->{'data.name2'} || '';
    $c->stash->{'data_id'}       = $c->{'request'}->{'parameters'}->{'data.id'}    || '';
    $c->stash->{'file_name'}     = $c->{'request'}->{'parameters'}->{'file'};
    $c->stash->{'file_line'}     = $c->{'request'}->{'parameters'}->{'line'};
    $c->stash->{'data_name'}     =~ s/^(.*)\ \-\ .*$/$1/gmx;
    $c->stash->{'type'}          = lc $c->stash->{'type'};
    $c->stash->{'show_object'}   = 0;
    $c->stash->{'show_secondary_select'} = 0;

    if(defined $c->{'request'}->{'parameters'}->{'service'} and defined $c->{'request'}->{'parameters'}->{'host'}) {
        $c->stash->{'type'}       = 'service';
        my $objs = $c->{'obj_db'}->get_objects_by_name('host', $c->{'request'}->{'parameters'}->{'host'}, 0);
        if(defined $objs->[0]) {
            my $services = $c->{'obj_db'}->get_services_for_host($objs->[0]);
            for my $type (keys %{$services}) {
                for my $name (keys %{$services->{$type}}) {
                    if($name eq $c->{'request'}->{'parameters'}->{'service'}) {
                        if(defined $services->{$type}->{$name}->{'svc'}) {
                            $c->stash->{'data_id'} = $services->{$type}->{$name}->{'svc'}->get_id();
                        } else {
                            $c->stash->{'data_id'} = $services->{$type}->{$name}->get_id();
                        }
                    }
                }
            }
        }
    }
    elsif(defined $c->{'request'}->{'parameters'}->{'host'}) {
        $c->stash->{'type'} = 'host';
        $c->stash->{'data_name'}  = $c->{'request'}->{'parameters'}->{'host'};
    }

    # remove leading plus signs (used to append to lists) and leading ! (used to negate in lists)
    $c->stash->{'data_name'} =~ s/^(\+|\!)//mx;

    # new object
    if($c->stash->{'data_id'} and $c->stash->{'data_id'} eq 'new') {
        $obj = Monitoring::Config::Object->new( type     => $c->stash->{'type'},
                                                coretype => $c->{'obj_db'}->{'coretype'},
                                              );
        my $files_root = $self->_set_files_stash($c);
        my $new_file   = $c->{'request'}->{'parameters'}->{'data.file'} || '';
        $new_file      =~ s/^\///gmx;
        my $file       = $c->{'obj_db'}->get_file_by_path($files_root.$new_file);
        if(defined $file) {
            if(defined $file and $file->{'readonly'}) {
                Thruk::Utils::set_message( $c, 'fail_message', 'File matches readonly pattern' );
                $c->stash->{'new_file'} = '/'.$new_file;
                return $obj;
            }
            $obj->{'file'} = $file;
        } else {
            # new file
            my $file = Monitoring::Config::File->new($files_root.$new_file, $c->{'obj_db'}->{'config'}->{'obj_readonly'}, $c->{'obj_db'}->{'coretype'});
            if(defined $file and $file->{'readonly'}) {
                Thruk::Utils::set_message( $c, 'fail_message', 'Failed to create new file: file matches readonly pattern' );
                $c->stash->{'new_file'} = '/'.$new_file;
                return $obj;
            }
            elsif(defined $file) {
                $obj->{'file'}         = $file;
                $c->{'obj_db'}->file_add($file);
            }
            else {
                $c->stash->{'new_file'} = '';
                Thruk::Utils::set_message( $c, 'fail_message', 'Failed to create new file: invalid path' );
                return $obj;
            }
        }
        $obj->set_uniq_id($c->{'obj_db'});
        return $obj;
    }

    # object by id
    if($c->stash->{'data_id'}) {
        $obj = $c->{'obj_db'}->get_object_by_id($c->stash->{'data_id'});
    }

    # link from file to an object?
    if(!defined $obj && defined $c->stash->{'file_name'} && defined $c->stash->{'file_line'}) {
        $obj = $c->{'obj_db'}->get_object_by_location($c->stash->{'file_name'}, $c->stash->{'file_line'});
        unless(defined $obj) {
            Thruk::Utils::set_message( $c, 'fail_message', 'No such object found in this file' );
        }
    }

    # object by name
    my @objs;
    if(!defined $obj && $c->stash->{'data_name'} ) {
        my $templates;
        if($c->stash->{'data_name'} =~ m/^ht:/mx or $c->stash->{'data_name'} =~ m/^st:/mx) {
            $templates=1; # only templates
        }
        if($c->stash->{'data_name'} =~ m/^ho:/mx or $c->stash->{'data_name'} =~ m/^se:/mx) {
            $templates=2; # no templates
        }
        $c->stash->{'data_name'} =~ s/^\w{2}://gmx;
        my $objs = $c->{'obj_db'}->get_objects_by_name($c->stash->{'type'}, $c->stash->{'data_name'}, 0, $c->stash->{'data_name2'});
        if(defined $templates) {
            my @newobjs;
            for my $o (@{$objs}) {
                if($templates == 1) {
                    push @newobjs, $o if $o->is_template();
                }
                if($templates == 2) {
                    push @newobjs, $o if !defined $o->{'conf'}->{'register'} or $o->{'conf'}->{'register'} != 0;
                }
            }
            @{$objs} = @newobjs;
        }
        if(defined $objs->[1]) {
            @objs = @{$objs};
            $c->stash->{'show_secondary_select'} = 1;
        }
        elsif(defined $objs->[0]) {
            $obj = $objs->[0];
        }
        elsif(!defined $obj) {
            Thruk::Utils::set_message( $c, 'fail_message', 'No such object. <a href="conf.cgi?sub=objects&action=new&amp;type='.$c->stash->{'type'}.'&amp;data.name='.$c->stash->{'data_name'}.'">Create it.</a>' );
        }
    }

    return $obj;
}

##########################################################
sub _translate_type {
    my $self = shift;
    my $type = shift;
    my $tt   = {
        'host_name'      => 'host',
        'hostgroup_name' => 'hostgroup',
    };
    return $tt->{$type} if defined $type;
    return;
}

##########################################################
sub _files_to_path {
    my $self   = shift;
    my $c      = shift;
    my $files  = shift;
    my $folder = { 'dirs' => {}, 'files' => {}, 'path' => '', 'date' => '' };

    for my $file (@{$files}) {
        my @parts    = split(/\//mx, $file->{'path'});
        my $filename = pop @parts;
        my $subdir = $folder;
        for my $dir (@parts) {
            $dir = $dir."/";
            my @stat = stat($subdir->{'path'}.$dir);
            $subdir->{'dirs'}->{$dir} = {
                                         'dirs'  => {},
                                         'files' => {},
                                         'path'  => $subdir->{'path'}.$dir,
                                         'date'  => Thruk::Utils::Filter::date_format($c, $stat[9]),
                                        } unless defined $subdir->{'dirs'}->{$dir};
            $subdir = $subdir->{'dirs'}->{$dir};
        }
        $subdir->{'files'}->{$filename} = {
                                           'date'     => Thruk::Utils::Filter::date_format($c, $file->{'mtime'}),
                                           'deleted'  => $file->{'deleted'},
                                           'readonly' => $file->{'readonly'},
                                        };
    }

    while(scalar keys %{$folder->{'files'}} == 0 && scalar keys %{$folder->{'dirs'}} == 1) {
        my @subdirs = keys %{$folder->{'dirs'}};
        my $dir = shift @subdirs;
        $folder = $folder->{'dirs'}->{$dir};
    }

    return($folder);
}

##########################################################
sub _set_files_stash {
    my $self = shift;
    my $c    = shift;

    my $all_files  = $c->{'obj_db'}->get_files();
    my $files_tree = $self->_files_to_path($c, $all_files);
    my $files_root = $files_tree->{'path'};
    my @filenames;
    for my $file (@{$all_files}) {
        my $filename = $file->{'path'};
        $filename    =~ s/^$files_root/\//gmx;
        push @filenames, $filename;
    }

    $c->stash->{'filenames_json'} = encode_json([{ name => 'files', data => [ sort @filenames ]}]);
    $c->stash->{'files_json'}     = encode_json($files_tree);
    return $files_root;
}

##########################################################
sub _object_revert {
    my $self = shift;
    my $c    = shift;
    my $obj  = shift;

    my $id = $obj->get_id();
    if(-e $obj->{'file'}->{'path'}) {
        my $oldobj;
        my $tmpfile = Monitoring::Config::File->new($obj->{'file'}->{'path'}, undef, $c->{'obj_db'}->{'coretype'});
        $tmpfile->update_objects();
        for my $o (@{$tmpfile->{'objects'}}) {
            if($id eq $o->get_id()) {
                $oldobj = $o;
                last;
            }
        }
        if(defined $oldobj) {
            $c->{'obj_db'}->update_object($obj, dclone($oldobj->{'conf'}), join("\n", @{$oldobj->{'comments'}}));
            Thruk::Utils::set_message( $c, 'success_message', ucfirst($obj->get_type()).' reverted successfully' );
        }
    }

    return $c->response->redirect('conf.cgi?sub=objects&data.id='.$obj->get_id());
}

##########################################################
sub _object_delete {
    my $self = shift;
    my $c    = shift;
    my $obj  = shift;

    my $refs = $c->{'obj_db'}->get_references($obj);
    if(scalar keys %{$refs}) {
        Thruk::Utils::set_message( $c, 'fail_message', ucfirst($c->stash->{'type'}).' has remaining references' );
        return $c->response->redirect('conf.cgi?sub=objects&action=listref&data.id='.$obj->get_id());
    }
    $c->{'obj_db'}->delete_object($obj);
    Thruk::Utils::set_message( $c, 'success_message', ucfirst($c->stash->{'type'}).' removed successfully' );
    return $c->response->redirect('conf.cgi?sub=objects&type='.$c->stash->{'type'});
}

##########################################################
sub _object_save {
    my $self = shift;
    my $c    = shift;
    my $obj  = shift;

    my $data        = $obj->get_data_from_param($c->{'request'}->{'parameters'});
    my $old_comment = join("\n", @{$obj->{'comments'}});
    my $new_comment = $c->{'request'}->{'parameters'}->{'conf_comment'};
    $new_comment    =~ s/\r//gmx;

    # save object
    $obj->{'file'}->{'errors'} = [];
    $c->{'obj_db'}->update_object($obj, $data, $new_comment);
    $c->stash->{'data_name'} = $obj->get_name();

    # just display the normal edit page if save failed
    if($obj->get_id() eq 'new') {
        $c->stash->{action} = '';
        return;
    }

    # only save or continue to raw edit?
    if(defined $c->{'request'}->{'parameters'}->{'send'} and $c->{'request'}->{'parameters'}->{'send'} eq 'raw edit') {
        return $c->response->redirect('conf.cgi?sub=objects&action=editor&file='.$obj->{'file'}->{'path'}.'&line='.$obj->{'line'}.'&data.id='.$obj->get_id().'&back=edit');
    } else {
        if(scalar @{$obj->{'file'}->{'errors'}} > 0) {
            Thruk::Utils::set_message( $c, 'fail_message', ucfirst($c->stash->{'type'}).' saved with errors', $obj->{'file'}->{'errors'} );
            return; # return, otherwise details would not be displayed
        } else {
            Thruk::Utils::set_message( $c, 'success_message', ucfirst($c->stash->{'type'}).' saved successfully' );
        }
        return $c->response->redirect('conf.cgi?sub=objects&data.id='.$obj->get_id());
    }

    return;
}

##########################################################
sub _object_move {
    my $self = shift;
    my $c    = shift;
    my $obj  = shift;

    my $files_root = $self->_set_files_stash($c);
    if($c->stash->{action} eq 'movefile') {
        my $new_file = $c->{'request'}->{'parameters'}->{'newfile'};
        $new_file    =~ s/^\///gmx;
        my $file     = $c->{'obj_db'}->get_file_by_path($files_root.$new_file);
        if(!defined $file) {
            Thruk::Utils::set_message( $c, 'fail_message', $files_root.$new_file." is not a valid file!" );
        } elsif($c->{'obj_db'}->move_object($obj, $file)) {
            Thruk::Utils::set_message( $c, 'success_message', ucfirst($c->stash->{'type'}).' \''.$obj->get_name().'\' moved successfully' );
        } else {
            Thruk::Utils::set_message( $c, 'fail_message', "Failed to move ".ucfirst($c->stash->{'type'}).' \''.$obj->get_name().'\'' );
        }
        return $c->response->redirect('conf.cgi?sub=objects&data.id='.$obj->get_id());
    }
    elsif($c->stash->{action} eq 'move') {
        $c->stash->{'template'}  = 'conf_objects_move.tt';
    }
    return;
}

##########################################################
sub _object_clone {
    my $self = shift;
    my $c    = shift;
    my $obj  = shift;

    my $files_root          = $self->_set_files_stash($c);
    $c->stash->{'new_file'} = $obj->{'file'}->{'path'};
    $c->stash->{'new_file'} =~ s/^$files_root/\//gmx;
    $obj = Monitoring::Config::Object->new(type     => $obj->get_type(),
                                           conf     => $obj->{'conf'},
                                           coretype => $c->{'obj_db'}->{'coretype'});
    return $obj;
}


##########################################################
sub _object_new {
    my $self = shift;
    my $c    = shift;

    $self->_set_files_stash($c);
    $c->stash->{'new_file'} = '';
    my $obj = Monitoring::Config::Object->new(type     => $c->stash->{'type'},
                                              name     => $c->stash->{'data_name'},
                                              coretype => $c->{'obj_db'}->{'coretype'});

    if(!defined $obj) {
        Thruk::Utils::set_message( $c, 'fail_message', 'Failed to create object' );
        return;
    }

    # set initial config from cgi parameters
    my $initial_conf = $obj->get_data_from_param($c->{'request'}->{'parameters'}, $obj->{'conf'});
    if($obj->has_object_changed($initial_conf)) {
        $c->{'obj_db'}->update_object($obj, $initial_conf );
    }

    return $obj;
}


##########################################################
sub _file_delete {
    my $self = shift;
    my $c    = shift;
    my $path = $c->{'request'}->{'parameters'}->{'path'} || '';
    $path    =~ s/^\#//gmx;

    my $files = $c->{'request'}->{'parameters'}->{'files'};
    for my $filename (ref $files eq 'ARRAY' ? @{$files} : ($files) ) {
        my $file = $c->{'obj_db'}->get_file_by_path($filename);
        if(defined $file) {
            $c->{'obj_db'}->file_delete($file);
        }
    }

    Thruk::Utils::set_message( $c, 'success_message', 'File(s) deleted successfully' );
    return $c->response->redirect('conf.cgi?sub=objects&action=browser#'.$path);
}


##########################################################
sub _file_undelete {
    my $self = shift;
    my $c    = shift;
    my $path = $c->{'request'}->{'parameters'}->{'path'} || '';
    $path    =~ s/^\#//gmx;

    my $files = $c->{'request'}->{'parameters'}->{'files'};
    for my $filename (ref $files eq 'ARRAY' ? @{$files} : ($files) ) {
        my $file = $c->{'obj_db'}->get_file_by_path($filename);
        if(defined $file) {
            $c->{'obj_db'}->file_undelete($file);
        }
    }

    Thruk::Utils::set_message( $c, 'success_message', 'File(s) recoverd successfully' );
    return $c->response->redirect('conf.cgi?sub=objects&action=browser#'.$path);
}


##########################################################
sub _file_save {
    my $self = shift;
    my $c    = shift;

    my $filename = $c->{'request'}->{'parameters'}->{'file'}    || '';
    my $content  = $c->{'request'}->{'parameters'}->{'content'} || '';
    my $lastline = $c->{'request'}->{'parameters'}->{'line'};
    my $file     = $c->{'obj_db'}->get_file_by_path($filename);
    my $lastobj;
    if(defined $file) {
        $lastobj = $file->update_objects_from_text($content, $lastline);
        $c->{'obj_db'}->_rebuild_index();
        my $files_root                   = $self->_set_files_stash($c);
        $c->{'obj_db'}->{'needs_commit'} = 1;
        $c->stash->{'file_name'}         = $file->{'path'};
        $c->stash->{'file_name'}         =~ s/^$files_root//gmx;
        if(scalar @{$file->{'errors'}} > 0) {
            Thruk::Utils::set_message( $c,
                                      'fail_message',
                                      'File '.$c->stash->{'file_name'}.' changed with errors',
                                      $file->{'errors'}
                                    );
        } else {
            Thruk::Utils::set_message( $c, 'success_message', 'File '.$c->stash->{'file_name'}.' changed successfully' );
        }
    } else {
        Thruk::Utils::set_message( $c, 'fail_message', 'File does not exist' );
    }

    if(defined $lastobj) {
        return $c->response->redirect('conf.cgi?sub=objects&data.id='.$lastobj->get_id());
    }
    return $c->response->redirect('conf.cgi?sub=objects&action=browser#'.$file->{'path'});
}

##########################################################
sub _file_editor {
    my $self = shift;
    my $c    = shift;

    my $files_root  = $self->_set_files_stash($c);
    my $filename    = $c->{'request'}->{'parameters'}->{'file'} || '';
    my $file        = $c->{'obj_db'}->get_file_by_path($filename);
    if(defined $file) {
        $c->stash->{'file'}          = $file;
        $c->stash->{'line'}          = $c->{'request'}->{'parameters'}->{'line'} || 1;
        $c->stash->{'back'}          = $c->{'request'}->{'parameters'}->{'back'} || '';
        $c->stash->{'file_link'}     = $file->{'path'};
        $c->stash->{'file_name'}     = $file->{'path'};
        $c->stash->{'file_name'}     =~ s/^$files_root//gmx;
        $c->stash->{'file_content'}  = $file->_get_new_file_content();
        $c->stash->{'template'}      = 'conf_objects_fileeditor.tt';
    } else {
        Thruk::Utils::set_message( $c, 'fail_message', 'File does not exist' );
    }
    return;
}


##########################################################
sub _file_browser {
    my $self = shift;
    my $c    = shift;

    $self->_set_files_stash($c);
    $c->stash->{'template'} = 'conf_objects_filebrowser.tt';
    return;
}

##########################################################
sub _host_list_services {
    my($self, $c, $obj) = @_;

    my $services = $c->{'obj_db'}->get_services_for_host($obj);
    $c->stash->{'services'} = $services ;

    $c->stash->{'template'} = 'conf_objects_host_list_services.tt';
    return;
}

##########################################################
sub _list_references {
    my($self, $c, $obj) = @_;
    my $refs = $c->{'obj_db'}->get_references($obj);
    my $data = {};
    for my $type (keys %{$refs}) {
        $data->{$type} = {};
        for my $id (keys %{$refs->{$type}}) {
            my $obj = $c->{'obj_db'}->get_object_by_id($id);
            $data->{$type}->{$obj->get_name()} = $id;
        }
    }
    $c->stash->{'data'}     = $data;
    $c->stash->{'template'} = 'conf_objects_listref.tt';
    return;
}

##########################################################
sub _get_plugins {
    my($self, $c) = @_;

    my $user_macros = $c->{'db'}->_read_resource_file($c->{'obj_db'}->{'config'}->{'obj_resource_file'});
    my $objects         = {};
    for my $macro (keys %{$user_macros}) {
        my $dir = $user_macros->{$macro};
        $dir = $dir.'/.';
        next unless -d $dir;
        if($dir =~ m|/plugins/|mx or $dir =~ m|/libexec/|mx) {
            $self->_set_plugins_for_directory($c, $dir, $macro, $objects);
        }
    }
    return $objects;
}

##########################################################
sub _set_plugins_for_directory {
    my($self, $c, $dir, $macro, $objects) = @_;
    my $files = $c->{'obj_db'}->_get_files_for_folder($dir);
    for my $file (@{$files}) {
        next if $file =~ m/\/utils\.pm/mx;
        next if $file =~ m/\/utils\.sh/mx;
        next if $file =~ m/\/p1\.pl/mx;
        if(-x $file) {
            my $shortfile = $file;
            $shortfile =~ s/$dir/$macro/gmx;
            $objects->{$shortfile} = $file;
        }
    }
    return $objects;
}

##########################################################
sub _get_plugin_help {
    my($self, $c, $name) = @_;

    my $cmd;
    my $plugins         = $self->_get_plugins($c);
    my $objects         = $c->{'obj_db'}->get_objects_by_name('command', $name);
    if(defined $objects->[0]) {
        my($file,$args) = split/\s+/mx, $objects->[0]->{'conf'}->{'command_line'}, 2;
        my $user_macros = $c->{'db'}->_read_resource_file($c->{'obj_db'}->{'config'}->{'obj_resource_file'});
        ($file)         = $c->{'db'}->_get_replaced_string($file, $user_macros);
        if(-x $file and ( $file =~ m|/plugins/|mx or $file =~ m|/libexec/|mx)) {
            $cmd = $file;
        }
    }
    if(defined $plugins->{$name}) {
        $cmd = $plugins->{$name};
    }
    my $help = 'help is only available for plugins!';
    if(defined $cmd) {
        eval {
            local $SIG{ALRM} = sub { die('alarm'); };
            alarm(5);
            $cmd = $cmd." -h 2>/dev/null";
            $help = `$cmd`;
            alarm(0);
        }
    }
    return $help;
}

##########################################################
sub _get_plugin_preview {
    my($self,$c,$command,$args,$host,$service) = @_;

    my $macros = $c->{'db'}->_get_macros({skip_user => 1, args => [split/\!/mx, $args]});
    $macros    = $c->{'db'}->_read_resource_file($c->{'obj_db'}->{'config'}->{'obj_resource_file'}, $macros);

    if(defined $host and $host ne '') {
        my $objects = $c->{'obj_db'}->get_objects_by_name('host', $host);
        if(defined $objects->[0]) {
            $macros = $objects->[0]->get_macros($c->{'obj_db'}, $macros);
        }
    }

    if(defined $service and $service ne '') {
        my $objects = $c->{'obj_db'}->get_objects_by_name('service', $service, 0, 'ho:'.$host);
        if(defined $objects->[0]) {
            $macros = $objects->[0]->get_macros($c->{'obj_db'}, $macros);
        }
    }

    my $cmd;
    my $objects         = $c->{'obj_db'}->get_objects_by_name('command', $command);
    if(defined $objects->[0]) {
        my($file,$cmd_args) = split/\s+/mx, $objects->[0]->{'conf'}->{'command_line'}, 2;
        ($file)    = $c->{'db'}->_get_replaced_string($file, $macros);
        if(-x $file and ( $file =~ m|/plugins/|mx or $file =~ m|/libexec/|mx)) {
            ($cmd) = $c->{'db'}->_get_replaced_string($objects->[0]->{'conf'}->{'command_line'}, $macros);
        }
    }
    my $output = 'plugin preview is only available for plugins!';
    if(defined $cmd) {
        eval {
            local $SIG{ALRM} = sub { die('alarm'); };
            alarm(45);
            $cmd = $cmd." 2>/dev/null";
            $output = `$cmd`;
            alarm(0);
        }
    }
    return $output;
}

##########################################################
sub _config_check {
    my($c) = @_;
    if(_cmd(undef, $c, $c->stash->{'peer_conftool'}->{'obj_check_cmd'})) {
        Thruk::Utils::set_message( $c, 'success_message', 'config check successfully' );
    } else {
        Thruk::Utils::set_message( $c, 'fail_message', 'config check failed!' );
    }
    _nice_check_output($c);

    $c->stash->{'obj_model_changed'} = 0 unless $c->{'request'}->{'parameters'}->{'refresh'};
    $c->stash->{'needs_commit'}      = $c->{'obj_db'}->{'needs_commit'};
    $c->stash->{'last_changed'}      = $c->{'obj_db'}->{'last_changed'};
    return;
}

##########################################################
sub _config_reload {
    my($c) = @_;
    if(_cmd(undef, $c, $c->stash->{'peer_conftool'}->{'obj_reload_cmd'})) {
        Thruk::Utils::set_message( $c, 'success_message', 'config reloaded successfully' );
        $c->stash->{'last_changed'} = 0;
        $c->stash->{'needs_commit'} = 0;
    } else {
        Thruk::Utils::set_message( $c, 'fail_message', 'config reload failed!' );
    }
    _nice_check_output($c);

    # wait until core responds
    for(1..30) {
        sleep(1);
        eval {
            $c->{'db'}->get_processinfo();
        };
        last unless $@;
    }

    $c->stash->{'obj_model_changed'} = 0 unless $c->{'request'}->{'parameters'}->{'refresh'};
    return;
}

##########################################################
sub _nice_check_output {
    my($c) = @_;
    $c->{'stash'}->{'output'} =~ s/(Error\s*:.*)$/<b><font color="red">$1<\/font><\/b>/gmx;
    $c->{'stash'}->{'output'} =~ s/(Warning\s*:.*)$/<b><font color="#FFA500">$1<\/font><\/b>/gmx;
    $c->{'stash'}->{'output'} =~ s/(CONFIG\s+ERROR.*)$/<b><font color="red">$1<\/font><\/b>/gmx;
    $c->{'stash'}->{'output'} =~ s/(\(config\s+file\s+'(.*?)',\s+starting\s+on\s+line\s+(\d+)\))/<a href="conf.cgi?sub=objects&amp;file=$2&amp;line=$3">$1<\/a>/gmx;
    $c->{'stash'}->{'output'} =~ s/\s+in\s+file\s+'(.*?)'\s+on\s+line\s+(\d+)/ in file <a href="conf.cgi?sub=objects&amp;type=file&amp;file=$1&amp;line=$2">'$1' on line $2<\/a>/gmx;
    $c->{'stash'}->{'output'} =~ s/\s+in\s+(\w+)\s+'(.*?)'/ in $1 '<a href="conf.cgi?sub=objects&amp;type=$1&amp;data.name=$2">$2<\/a>'/gmx;
    $c->{'stash'}->{'output'} =~ s/Warning:\s+(\w+)\s+'(.*?)'\s+/Warning: $1 '<a href="conf.cgi?sub=objects&amp;type=$1&amp;data.name=$2">$2<\/a>' /gmx;
    $c->{'stash'}->{'output'} =~ s/Error:\s+(\w+)\s+'(.*?)'\s+/Error: $1 '<a href="conf.cgi?sub=objects&amp;type=$1&amp;data.name=$2">$2<\/a>' /gmx;
    $c->{'stash'}->{'output'} =~ s/Error\s*:\s*the\s+service\s+([^\s]+)\s+on\s+host\s+'([^']+)'/Error: the service <a href="conf.cgi?sub=objects&amp;type=service&amp;data.name=$1&amp;data.name2=$2">$1<\/a> on host '$2'/gmx;
    $c->{'stash'}->{'output'} = "<pre>".$c->{'stash'}->{'output'}."</pre>";
    return;
}

##########################################################
# check for external reloads
sub _check_external_reload {
    my($c) = @_;

    return unless defined $c->{'obj_db'}->{'last_changed'};

    if($c->{'obj_db'}->{'last_changed'} > 0) {
        my $last_reloaded = $c->stash->{'pi_detail'}->{$c->stash->{'param_backend'}}->{'program_start'} || 0;
        if($last_reloaded > $c->{'obj_db'}->{'last_changed'}) {
            $c->{'obj_db'}->{'last_changed'} = 0;
            $c->stash->{'last_changed'}      = 0;
        }
    }
    return;
}

##########################################################
# return nicer addon name
sub _nice_addon_name {
    my($name) = @_;
    my $dir = $name;
    $dir =~ s/\/+$//gmx;
    $dir =~ s/^.*\///gmx;
    my $nicename = join(' ', map(ucfirst, split(/_/mx, $dir)));
    return($nicename, $dir);
}

##########################################################

=head1 AUTHOR

Sven Nierlein, 2011, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
