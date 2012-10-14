package Thruk::Model::Objects;

use strict;
use warnings;

use base qw/ Catalyst::Model::Objects::Class /;

=head1 NAME

Thruk::Model::Thruk - Thruk Objects Model Class

=head1 SYNOPSIS

See L<Thruk>.

=head1 DESCRIPTION

Thruk::Class Model Class.

=head1 AUTHOR

Sven Nierlein, 2010, <nierlein@cpan.org>

=head1 LICENSE

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself. See L<perlartistic>.

=cut

__PACKAGE__->meta->make_immutable;

1;
