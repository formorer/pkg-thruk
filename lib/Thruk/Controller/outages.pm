package Thruk::Controller::outages;

use strict;
use warnings;
use utf8;
use parent 'Catalyst::Controller';

=head1 NAME

Thruk::Controller::outages - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut


=head2 index

=cut

##########################################################
sub index :Path :Args(0) :MyAction('AddDefaults') {
    my ( $self, $c ) = @_;


    my $outages = $c->{'db'}->get_hosts(filter => [ Thruk::Utils::Auth::get_auth_filter($c, 'hosts'),
                                                    state => 1,
                                                    childs => { '!=' => undef }
                                                  ]);

    if(defined $outages and scalar @{$outages} > 0) {
        my $hostcomments = {};
        my $tmp = $c->{'db'}->get_comments(filter => [ Thruk::Utils::Auth::get_auth_filter($c, 'comments'), service_description => undef ]);
        for my $com (@{$tmp}) {
            $hostcomments->{$com->{'host_name'}} = 0 unless defined $hostcomments->{$com->{'host_name'}};
            $hostcomments->{$com->{'host_name'}}++;

        }

        my $tmp2 = $c->{'db'}->get_hosts(filter => [ Thruk::Utils::Auth::get_auth_filter($c, 'hosts') ] );
        my $all_hosts = Thruk::Utils::array2hash($tmp2, 'name');
        for my $host (@{$outages}) {

            # get number of comments
            $host->{'comment_count'} = 0;
            $host->{'comment_count'} = $hostcomments->{$host->{'name'}} if defined $hostcomments->{$host->{'name'}};

            # count number of affected hosts / services
            my($affected_hosts,$affected_services) = $self->_count_affected_hosts_and_services($c, $host->{'name'}, $all_hosts);
            $host->{'affected_hosts'}    = $affected_hosts;
            $host->{'affected_services'} = $affected_services;

            $host->{'severity'} = int($affected_hosts + $affected_services/4);
        }
    }

    # sort by severity
    my $sortedoutages = Thruk::Backend::Manager::_sort($c, $outages, { 'DESC' => 'severity' });

    $c->stash->{outages}        = $sortedoutages;
    $c->stash->{title}          = 'Network Outages';
    $c->stash->{infoBoxTitle}   = 'Network Outages';
    $c->stash->{page}           = 'outages';
    $c->stash->{template}       = 'outages.tt';

    Thruk::Utils::ssi_include($c);

    return 1;
}

##########################################################
# create the status details page
sub _count_affected_hosts_and_services {
    my($self, $c, $host, $all_hosts ) = @_;

    my $affected_hosts    = 0;
    my $affected_services = 0;

    return(0,0) if !defined $all_hosts->{$host};

    if(defined $all_hosts->{$host}->{'childs'} and $all_hosts->{$host}->{'childs'} ne '') {
        for my $child (@{$all_hosts->{$host}->{'childs'}}) {
            my($child_affected_hosts,$child_affected_services) = $self->_count_affected_hosts_and_services($c, $child, $all_hosts);
            $affected_hosts    += $child_affected_hosts;
            $affected_services += $child_affected_services;
        }
    }

    # add number of directly affected hosts
    $affected_hosts++;

    # add number of directly affected services
    $affected_services += $all_hosts->{$host}->{'num_services'};

    return($affected_hosts, $affected_services);
}

=head1 AUTHOR

Sven Nierlein, 2009, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
