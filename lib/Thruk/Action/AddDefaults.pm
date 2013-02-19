package Thruk::Action::AddDefaults;

=head1 NAME

Thruk::Action::AddDefaults - Add Defaults to the context

=head1 DESCRIPTION

loads cgi.cfg

creates backend manager

=head1 METHODS

=cut


use strict;
use warnings;
use Moose;
use Carp;
use Data::Dumper;

extends 'Catalyst::Action';

########################################
before 'execute' => sub {
    add_defaults(0, @_);
};

after 'execute' => sub {
    after_execute(@_);
};


########################################

=head2 add_defaults

    add default values and create backend connections

=cut

sub add_defaults {
    my ( $safe, $self, $controller, $c, $test ) = @_;
    $safe = 0 unless defined $safe;

    $c->stats->profile(begin => "AddDefaults::add_defaults");

    $c->stash->{'defaults_added'} = 1;

    ###############################
    # parse cgi.cfg
    Thruk::Utils::read_cgi_cfg($c);

    ###############################
    $c->stash->{'escape_html_tags'}      = exists $c->config->{'cgi_cfg'}->{'escape_html_tags'}  ? $c->config->{'cgi_cfg'}->{'escape_html_tags'}  : 1;
    $c->stash->{'show_context_help'}     = exists $c->config->{'cgi_cfg'}->{'show_context_help'} ? $c->config->{'cgi_cfg'}->{'show_context_help'} : 0;
    $c->stash->{'info_popup_event_type'} = $c->config->{'info_popup_event_type'} || 'onmouseover';

    ###############################
    $c->stash->{'enable_shinken_features'} = 0;
    if(exists $c->config->{'enable_shinken_features'}) {
        $c->stash->{'enable_shinken_features'} = $c->config->{'enable_shinken_features'};
    }

    ###############################
    $c->stash->{'enable_icinga_features'} = 0;
    if(exists $c->config->{'enable_icinga_features'}) {
        $c->stash->{'enable_icinga_features'} = $c->config->{'enable_icinga_features'};
    }

    ###############################
    # Authentication
    $c->log->debug("checking auth");
    if($c->request->uri->path_query =~ m~^(/thruk|/\w+/thruk)/cgi-bin/remote\.cgi~mx) {
        $c->log->debug("remote.cgi does not use authentication");
    }
    elsif($c->request->uri->path_query =~ m~^(/thruk|/\w+/thruk)/cgi-bin/login\.cgi~mx) {
        $c->log->debug("login.cgi does not use authentication");
    } else {
        unless ($c->user_exists) {
            $c->log->debug("user not authenticated yet");
            unless ($c->authenticate( {} )) {
                # return 403 forbidden or kick out the user in other way
                $c->log->debug("user is not authenticated");
                return $c->detach('/error/index/10');
            };
        }
        $c->log->debug("user authenticated as: ".$c->user->get('username'));
        if($c->user_exists) {
            $c->stash->{'remote_user'}= $c->user->get('username');
        }
    }

    ###############################
    # no backend?
    return unless defined $c->{'db'};

    ###############################
    # read cached data
    my $cache = $c->cache;
    my $cached_data = {};
    if(defined $c->stash->{'remote_user'} and $c->stash->{'remote_user'} ne '?') {
        $cached_data = $cache->get($c->stash->{'remote_user'});
    }

    ###############################
    my($disabled_backends,$has_groups) = _set_enabled_backends($c);

    ###############################
    # add program status
    # this is also the first query on every page, so do the
    # backend availability checks here
    $c->stats->profile(begin => "AddDefaults::get_proc_info");
    my $last_program_restart = 0;
    my $retrys = 1;
    # try 3 times if all cores are local
    $retrys = 3 if scalar keys %{$c->{'db'}->{'state_hosts'}} == 0;

    for my $x (1..$retrys) {
        eval {
            $last_program_restart = _set_processinfo($c, $cache, $cached_data);
        };
        last unless $@;
        $c->log->debug("retry $x, data source error: $@");
        last if $x == $retrys;
        # reset failed states, otherwise retry would be useless
        $c->{'db'}->reset_failed_backends();
        sleep 1;
    }
    if($@) {
        # side.html and some other pages should not be redirect to the error page on backend errors
        _set_possible_backends($c, $disabled_backends);
        return if $safe;
        $c->log->error("data source error: $@");
        return $c->detach('/error/index/9');
    }
    $c->stash->{'last_program_restart'} = $last_program_restart;

    ###############################
    # read cached data again, groups could have changed
    $cached_data = $cache->get($c->stash->{'remote_user'}) if defined $c->stash->{'remote_user'};
    $c->log->debug("cached data:");
    $c->log->debug(Dumper($cached_data));

    ###############################
    # disable backends by groups
    if(!defined $ENV{'THRUK_BACKENDS'} and $has_groups and defined $c->{'db'}) {
        $disabled_backends = _disable_backends_by_group($c, $disabled_backends, $cached_data);
    }
    _set_possible_backends($c, $disabled_backends);

    ###############################
    die_when_no_backends($c);

    $c->stats->profile(end => "AddDefaults::get_proc_info");

    ###############################
    # set some more roles
    Thruk::Utils::set_dynamic_roles($c);

    ###############################
    # do we have only shinken backends?
    unless(exists $c->config->{'enable_shinken_features'}) {
        if(defined $c->stash->{'pi_detail'} and ref $c->stash->{'pi_detail'} eq 'HASH' and scalar keys %{$c->stash->{'pi_detail'}} > 0) {
            $c->stash->{'enable_shinken_features'} = 1;
            for my $b (values %{$c->stash->{'pi_detail'}}) {
                next unless defined $b->{'peer_key'};
                next unless defined $c->stash->{'backend_detail'}->{$b->{'peer_key'}};
                if(defined $b->{'data_source_version'} and $b->{'data_source_version'} !~ m/\-shinken/mx) {
                    $c->stash->{'enable_shinken_features'} = 0;
                    last;
                }
            }
        }
    }

    ###############################
    # do we have only icinga backends?
    if(!exists $c->config->{'enable_icinga_features'} and defined $ENV{'OMD_ROOT'}) {
        # get core from init script link (omd)
        my $init = $ENV{'OMD_ROOT'}.'/etc/init.d/core';
        if(-e $ENV{'OMD_ROOT'}.'/etc/init.d/core') {
            my $core = readlink($ENV{'OMD_ROOT'}.'/etc/init.d/core');
            $c->stash->{'enable_icinga_features'} = 1 if $core eq 'icinga';
        }
    }

    ###############################
    # expire acks?
    $c->stash->{'has_expire_acks'} = 0;
    $c->stash->{'has_expire_acks'} = 1 if $c->stash->{'enable_icinga_features'}
                                       or $c->stash->{'enable_shinken_features'};

    # make stash available for our backends
    $c->{'db'}->set_stash($c->stash);

    $c->stash->{'navigation'} = "";
    if( $c->config->{'use_frames'} == 0 ) {
        Thruk::Utils::Menu::read_navigation($c);
    }

    # config edit buttons?
    $c->stash->{'show_config_edit_buttons'} = 0;
    if(    $c->config->{'use_feature_configtool'}
       and $c->check_user_roles("authorized_for_configuration_information")
       and $c->check_user_roles("authorized_for_system_commands")
      ) {
        # get backends with object config
        for my $peer (@{$c->{'db'}->get_peers(1)}) {
            if(scalar keys %{$peer->{'configtool'}} > 0) {
                $c->stash->{'show_config_edit_buttons'} = $c->config->{'show_config_edit_buttons'};
                $c->stash->{'backends_with_obj_config'}->{$peer->{'key'}} = 1;
            }
            else {
                $c->stash->{'backends_with_obj_config'}->{$peer->{'key'}} = 0;
            }
        }
    }

    ###############################
    # show sound preferences?
    $c->stash->{'has_cgi_sounds'} = 0;
    $c->stash->{'show_sounds'}    = 1;
    for my $key (qw/host_unreachable host_down service_critical service_warning service_unknown normal/) {
        if(defined $c->config->{'cgi_cfg'}->{$key."_sound"}) {
            $c->stash->{'has_cgi_sounds'} = 1;
            last;
        }
    }

    ###############################
    # user / group specific config?
    if($c->stash->{'remote_user'}) {
        $c->stash->{'config_adjustments'} = {};
        for my $group (sort keys %{$c->cache->get($c->stash->{'remote_user'})->{'contactgroups'}}) {
            if(defined $c->config->{'Group'}->{$group}) {
                for my $key (keys %{$c->config->{'Group'}->{$group}}) {
                    $c->stash->{'config_adjustments'}->{$key} = $c->config->{$key} unless defined $c->stash->{'config_adjustments'}->{$key};
                    $c->config->{$key} = $c->config->{'Group'}->{$group}->{$key};
                }
            }
        }
        if(defined $c->config->{'User'}->{$c->stash->{'remote_user'}}) {
            for my $key (keys %{$c->config->{'User'}->{$c->stash->{'remote_user'}}}) {
                $c->stash->{'config_adjustments'}->{$key} = $c->config->{$key} unless defined $c->stash->{'config_adjustments'}->{$key};
                $c->config->{$key} = $c->config->{'User'}->{$c->stash->{'remote_user'}}->{$key};
            }
        }

        # reapply config defaults and config conversions
        if(scalar keys %{$c->stash->{'config_adjustments'}} > 0) {
            Thruk::Config::set_default_config($c->config);
        }
    }

    ###############################
    $c->stats->profile(end => "AddDefaults::add_defaults");
    return;
}

########################################

=head2 after_execute

    last chance to change stash

=cut

sub after_execute {
    my ( $self, $controller, $c, $test ) = @_;

    $c->stats->profile(begin => "AddDefaults::after");

    if(defined $c->config->{'cgi_cfg'}->{'refresh_rate'} and (!defined $c->stash->{'no_auto_reload'} or $c->stash->{'no_auto_reload'} == 0)) {
        $c->stash->{'refresh_rate'} = $c->config->{'cgi_cfg'}->{'refresh_rate'};
    }
    $c->stash->{'refresh_rate'} = $c->{'request'}->{'parameters'}->{'refresh'} if defined $c->{'request'}->{'parameters'}->{'refresh'};

    $c->stats->profile(end => "AddDefaults::after");
    return;
}



########################################

=head2 _set_possible_backends

  _set_possible_backends($c, $disabled_backends)

  possible values are:
    0 = reachable
    1 = unreachable
    2 = hidden by user
    3 = hidden by backend param
    4 = disabled by missing group auth

   override by the config tool
    5 = disabled (overide by config tool)
    6 = hidden   (overide by config tool)
    7 = up       (overide by config tool)

=cut
sub _set_possible_backends {
    my ($c,$disabled_backends) = @_;

    my @possible_backends;
    for my $b (@{$c->{'db'}->get_peers($c->stash->{'config_backends_only'} || 0)}) {
        push @possible_backends, $b->{'key'};
    }

    my %backend_detail;
    my @new_possible_backends;

    for my $back (@possible_backends) {
        if(defined $disabled_backends->{$back} and $disabled_backends->{$back} == 4) {
            $c->{'db'}->disable_backend($back);
        }
        if(!defined $disabled_backends->{$back} or $disabled_backends->{$back} != 4) {
            my $peer = $c->{'db'}->get_peer_by_key($back);
            $backend_detail{$back} = {
                'name'       => $peer->{'name'},
                'addr'       => $peer->{'addr'},
                'type'       => $peer->{'type'},
                'disabled'   => $disabled_backends->{$back} || 0,
                'running'    => 0,
                'last_error' => defined $peer->{'last_error'} ? $peer->{'last_error'} : '',
            };
            if(ref $c->stash->{'pi_detail'} eq 'HASH' and defined $c->stash->{'pi_detail'}->{$back}->{'program_start'}) {
                $backend_detail{$back}->{'running'} = 1;
            }
            $backend_detail{$back}->{'has_curl'} = $peer->{'class'}->{'has_curl'} || 0;
            # set combined state
            $backend_detail{$back}->{'state'} = 1; # down
            if($backend_detail{$back}->{'running'}) { $backend_detail{$back}->{'state'} = 0; }       # up
            if($backend_detail{$back}->{'disabled'} == 2) { $backend_detail{$back}->{'state'} = 2; } # hidden
            if($backend_detail{$back}->{'disabled'} == 3) { $backend_detail{$back}->{'state'} = 3; } # unused
            push @new_possible_backends, $back;
        }
    }

    $c->stash->{'backends'}           = \@new_possible_backends;
    $c->stash->{'backend_detail'}     = \%backend_detail;

    return;
}

########################################
sub _disable_backends_by_group {
    my ($c,$disabled_backends, $cached_data) = @_;

    my $contactgroups = $cached_data->{'contactgroups'};
    for my $peer (@{$c->{'db'}->get_peers()}) {
        if(defined $peer->{'groups'}) {
            for my $group (split/\s*,\s*/mx, $peer->{'groups'}) {
                if(defined $contactgroups->{$group}) {
                    $c->log->debug("found contact ".$c->user->get('username')." in contactgroup ".$group);
                    # delete old completly hidden state
                    delete $disabled_backends->{$peer->{'key'}};
                    # but disabled by cookie?
                    if(defined $c->request->cookie('thruk_backends')) {
                        for my $val (@{$c->request->cookie('thruk_backends')->{'value'}}) {
                            my($key, $value) = split/=/mx, $val;
                            if(defined $value and $key eq $peer->{'key'}) {
                                $disabled_backends->{$key} = $value;
                            }
                        }
                    }
                    last;
                }
            }
        }
    }

    return $disabled_backends;
}

########################################
sub _any_backend_enabled {
    my ($c) = @_;
    for my $peer_key (keys %{$c->stash->{'backend_detail'}}) {
        return 1 if(
             $c->stash->{'backend_detail'}->{$peer_key}->{'disabled'} == 0
          or $c->stash->{'backend_detail'}->{$peer_key}->{'disabled'} == 5);

    }
    return;
}

########################################
sub _set_processinfo {
    my($c, $cache, $cached_data) = @_;
    my $last_program_restart     = 0;
    my $processinfo              = $c->{'db'}->get_processinfo();
    $processinfo                 = {} unless defined $processinfo;
    $processinfo                 = {} if(ref $processinfo eq 'ARRAY' && scalar @{$processinfo} == 0);
    my $overall_processinfo      = Thruk::Utils::calculate_overall_processinfo($processinfo);
    $c->stash->{'pi'}            = $overall_processinfo;
    $c->stash->{'pi_detail'}     = $processinfo;
    $c->stash->{'has_proc_info'} = 1;

    # set last programm restart
    if(ref $processinfo eq 'HASH') {
        for my $backend (keys %{$processinfo}) {
            $last_program_restart = $processinfo->{$backend}->{'program_start'} if $last_program_restart < $processinfo->{$backend}->{'program_start'};
        }
    }

    # check if we have to build / clean our per user cache
    if(   !defined $cached_data
       or !defined $cached_data->{'prev_last_program_restart'}
       or $cached_data->{'prev_last_program_restart'} < $last_program_restart
      ) {
        if(defined $c->stash->{'remote_user'}) {
            my $contactgroups = $c->{'db'}->get_contactgroups_by_contact($c, $c->stash->{'remote_user'}, 1);

            $cached_data = {
                'prev_last_program_restart' => $last_program_restart,
                'contactgroups'             => $contactgroups,
            };
            $cache->set($c->stash->{'remote_user'}, $cached_data) if defined $c->stash->{'remote_user'};
            $c->log->debug("creating new user cache for ".$c->stash->{'remote_user'});
        }
    }

    # check our backends uptime
    if(defined $c->config->{'delay_pages_after_backend_reload'} and $c->config->{'delay_pages_after_backend_reload'} > 0) {
        my $delay_pages_after_backend_reload = $c->config->{'delay_pages_after_backend_reload'};
        for my $backend (keys %{$processinfo}) {
            my $delay = int($processinfo->{$backend}->{'program_start'} + $delay_pages_after_backend_reload - time());
            if($delay > 0) {
                $c->log->debug("delaying page delivery by $delay seconds...");
                sleep($delay);
            }
        }
    }
    return($last_program_restart);
}

########################################
sub _set_enabled_backends {
    my($c, $backends) = @_;

    # first all backends are enabled
    if(defined $c->{'db'}) {
        $c->{'db'}->enable_backends();
    }

    my $backend  = $c->{'request'}->{'parameters'}->{'backend'} || $c->{'request'}->{'parameters'}->{'backends'} || '';
    $c->stash->{'param_backend'} = $backend;
    my $disabled_backends = {};
    my $num_backends      = @{$c->{'db'}->get_peers()};

    ###############################
    # by args
    if(defined $backends) {
        $c->log->debug('_set_enabled_backends() by args');
        # reset
        $disabled_backends = {};
        for my $peer (@{$c->{'db'}->get_peers()}) {
            $disabled_backends->{$peer->{'key'}} = 2; # set all hidden
        }
        if(ref $backends eq '') {
            @{$backends} = split(/\s*,\s*/mx, $backends);
        }
        for my $b (@{$backends}) {
            # peer key can be name too
            my $peer = $c->{'db'}->get_peer_by_key($b);
            die("got no peer for: ".$b) unless defined $peer;
            $disabled_backends->{$peer->peer_key()} = 0;
        }
    }
    ###############################
    # by env
    elsif(defined $ENV{'THRUK_BACKENDS'}) {
        $c->log->debug('_set_enabled_backends() by env: '.Dumper($ENV{'THRUK_BACKENDS'}));
        # reset
        $disabled_backends = {};
        for my $peer (@{$c->{'db'}->get_peers()}) {
            $disabled_backends->{$peer->{'key'}} = 2; # set all hidden
        }
        for my $b (split(/,/mx, $ENV{'THRUK_BACKENDS'})) {
            $disabled_backends->{$b} = 0;
        }
    }

    ###############################
    # by param
    elsif($backend ne '') {
        $c->log->debug('_set_enabled_backends() by param');
        # reset
        $disabled_backends = {};
        for my $peer (@{$c->{'db'}->get_peers()}) {
            $disabled_backends->{$peer->{'key'}} = 2;  # set all hidden
        }
        for my $b (ref $backend eq 'ARRAY' ? @{$backend} : split/,/mx, $backend) {
            $disabled_backends->{$b} = 0;
        }
    }

    ###############################
    # by cookie
    elsif($num_backends > 1 and defined $c->request->cookie('thruk_backends')) {
        $c->log->debug('_set_enabled_backends() by cookie');
        for my $val (@{$c->request->cookie('thruk_backends')->{'value'}}) {
            my($key, $value) = split/=/mx, $val;
            next unless defined $value;
            $disabled_backends->{$key} = $value;
        }
    }
    elsif(defined $c->{'db'}) {
        $c->log->debug('_set_enabled_backends() using defaults');
        $disabled_backends = $c->{'db'}->disable_hidden_backends($disabled_backends);
    }

    ###############################
    # groups affected?
    my $has_groups = 0;
    if(defined $c->{'db'}) {
        for my $peer (@{$c->{'db'}->get_peers()}) {
            if(defined $peer->{'groups'}) {
                $has_groups = 1;
                $disabled_backends->{$peer->{'key'}} = 4;  # completly hidden
            }
        }
        $c->{'db'}->disable_backends($disabled_backends);
    }
    $c->log->debug("backend groups filter enabled") if $has_groups;

    # renew state of connections
    if($num_backends > 1 and $c->config->{'check_local_states'}) {
        $disabled_backends = $c->{'db'}->set_backend_state_from_local_connections($c->cache, $disabled_backends);
    }

    # when set by args, update
    if(defined $backends) {
        _set_possible_backends($c, $disabled_backends);
    }
    $c->log->debug('disabled_backends: '.Dumper($disabled_backends));
    return($disabled_backends, $has_groups);
}

########################################

=head2 die_when_no_backends

    die unless there are any backeds defined and enabled

=cut
sub die_when_no_backends {
    my($c) = @_;
    if(!defined $c->stash->{'pi_detail'} and _any_backend_enabled($c)) {
        $c->log->error("got no result from any backend, please check backend connection and logfiles");
        return $c->detach('/error/index/9');
    }
    return;
}


########################################
__PACKAGE__->meta->make_immutable;

########################################

=head1 AUTHOR

Sven Nierlein, 2009, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
