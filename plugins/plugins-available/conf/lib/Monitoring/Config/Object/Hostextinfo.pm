package Monitoring::Config::Object::Hostextinfo;

use strict;
use warnings;
use Moose;
extends 'Monitoring::Config::Object::Parent';

=head1 NAME

Monitoring::Config::Object::Hostextinfo - Hostextinfo Object Configuration

=head1 DESCRIPTION

Defaults for hostextinfo objects

=cut

##########################################################

$Monitoring::Config::Object::Hostextinfo::Defaults = {
    'name'              => { type => 'STRING', cat => 'Extended' },
    'use'               => { type => 'LIST', link => 'hostextinfo', cat => 'Basic' },
    'register'          => { type => 'BOOL', cat => 'Extended' },

    'host_name'         => { type => 'DEPRECATED' },
    'notes'             => { type => 'DEPRECATED' },
    'notes_url'         => { type => 'DEPRECATED' },
    'action_url'        => { type => 'DEPRECATED' },
    'icon_image'        => { type => 'DEPRECATED' },
    'icon_image_alt'    => { type => 'DEPRECATED' },
    'vrml_image'        => { type => 'DEPRECATED' },
    'statusmap_image'   => { type => 'DEPRECATED' },
    '2d_coords'         => { type => 'DEPRECATED' },
    '3d_coords'         => { type => 'DEPRECATED' },
    'hostgroup_name'    => { type => 'DEPRECATED' },
    'hostgroup'         => { type => 'ALIAS', 'name' => 'hostgroup_name' },
    'gd2_image'         => { type => 'ALIAS', 'name' => 'statusmap_image' },
};

##########################################################

=head1 METHODS

=head2 BUILD

return new object

=cut
sub BUILD {
    my $class = shift || __PACKAGE__;
    my $self = {
        'type'        => 'hostextinfo',
        'deprecated'  => 1,
        'primary_key' => [ 'host_name', 'hostgroup_name' ],
        'default'     => $Monitoring::Config::Object::Hostextinfo::Defaults,
    };
    bless $self, $class;
    return $self;
}


##########################################################

=head2 parse

parse the object config

=cut
sub parse {
    my $self = shift;
    return $self->SUPER::parse($self->{'default'});
}


=head1 AUTHOR

Sven Nierlein, 2011, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
