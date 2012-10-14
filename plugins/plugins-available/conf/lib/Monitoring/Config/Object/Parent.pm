package Monitoring::Config::Object::Parent;

use strict;
use warnings;
use Carp;
use Digest::MD5 qw(md5_hex);
use Storable qw(dclone);
use Monitoring::Config::Help;

=head1 NAME

Monitoring::Config::Object::Parent - Object Configuration Template

=head1 DESCRIPTION

Object Configuration Template

=head1 METHODS

=cut

##########################################################

=head2 parse

parse the object config

=cut
sub parse {
    my $self         = shift;
    my $fields       = shift;
    my $parse_errors = [];

    delete $self->{'name'};

    for my $attr (keys %{$self->{'conf'}}) {
        my $value = $self->{'conf'}->{$attr};

        # empty values are valid
        $value = '' unless defined $value;

        if(defined $fields->{$attr}) {
            my $field = $fields->{$attr};

            # is it an alias?
            if($field->{'type'} eq 'ALIAS') {
                delete $self->{'conf'}->{$attr};

                $attr  = $field->{'name'};
                confess("alias does not exist: ".$attr." -> ".$field->{'name'}." ") unless defined $fields->{$attr}->{'type'};
                $field = $fields->{$attr};

                $self->{'conf'}->{$attr} = $value;
            }

            if($field->{'type'} eq 'LIST' or $field->{'type'} eq 'ENUM') {
                if(defined $value) {
                    my @list = split/\s*,\s*/mx, $value;
                    # remove empty elements
                    @list = grep {!/^\s*$/mx} @list;
                    $self->{'conf'}->{$attr} = \@list;
                } else {
                    $self->{'conf'}->{$attr} = [];
                }
            }
        } elsif(substr($attr, 0, 1) eq '_') {
            $self->{'conf'}->{$attr} = $value;
        } else {
            if($self->{'type'} eq 'timeperiod' and $value =~ m/^\d{1,2}:\d{1,2}\-\d{1,2}:\d{1,2}/gmx) {
                $self->{'conf'}->{$attr} = $value;
            } else {
                push @{$parse_errors}, "unknown attribute: $attr in ".Thruk::Utils::Conf::_link_obj($self);
            }
        }
    }

    return $parse_errors;
}

##########################################################

=head2 as_text

in scalar context returns this object as text.

in list context, returns [$text, $nr_comment_lines, $nr_object_lines]

=cut
sub as_text {
    my($self) = @_;

    # save comments
    my $text             = "";
    my $nr_object_lines  = 0;
    for my $line (@{$self->{'comments'}}) {
        $line =~ s/^#\s+//gmxo;
        $line =~ s/^;\s+//gmxo;
        unless(substr($line,0,1) eq '#' or substr($line,0,1) eq ';') {
            $line = '# '.$line;
        }
        $line =~ s/\s+$//gmx;
        $text .= $line."\n";
    }
    my $nr_comment_lines = scalar @{$self->{'comments'}};

    # save object itself
    $text .= "define ".$self->{'type'}." {\n"; $nr_object_lines++;

    for my $key (@{$self->get_sorted_keys()}) {
        my $value;
        if(defined $self->{'default'}->{$key}
            and ($self->{'default'}->{$key}->{'type'} eq 'LIST'
              or $self->{'default'}->{$key}->{'type'} eq 'ENUM'
            )
        ) {
            $value = join(',', @{$self->{'conf'}->{$key}});
        } else {
            $value = $self->{'conf'}->{$key};
        }
        # empty values are valid syntax
        $value = '' unless defined $value;
        $text .= sprintf "  %-30s %s\n", $key, $value;
        $nr_object_lines++
    }
    $text .= "}\n\n";
    $nr_object_lines += 2;

    if(wantarray) {
        return($text, $nr_comment_lines, $nr_object_lines);
    }
    return $text;
}

##########################################################

=head2 is_template

returns 1 if this is a template

=cut
sub is_template {
    my($self) = @_;
    return 1 if (defined $self->{'conf'}->{'register'} and $self->{'conf'}->{'register'} == 0);
    return 1 if $self->get_template_name();
    return 0;
}

##########################################################

=head2 get_template_name

return the objects template name or undef

=cut
sub get_template_name {
    my $self = shift;
    # in case there is no name set, use the primary name
    if(defined $self->{'conf'}->{'register'} and $self->{'conf'}->{'register'} == 0 and !defined $self->{'conf'}->{'name'} and defined $self->{'conf'}->{$self->{'primary_key'}}) {
        return $self->{'conf'}->{$self->{'primary_key'}};
    }
    return $self->{'conf'}->{'name'};
}


##########################################################

=head2 get_name

return the objects name

=cut
sub get_name {
    my $self = shift;
    if($self->is_template()) {
        return $self->get_template_name();
    }
    return $self->get_primary_name();
}


##########################################################

=head2 get_id

return the objects id

=cut
sub get_id {
    my $self = shift;
    return $self->{'id'};
}


##########################################################

=head2 get_type

return the objects type

=cut
sub get_type {
    my $self = shift;
    return $self->{'type'};
}


##########################################################

=head2 get_primary_name

return the primary objects name

=cut
sub get_primary_name {
    my $self = shift;
    my $full = shift || 0;
    my $conf = shift || $self->{'conf'};

    return if defined $conf->{'register'} and $conf->{'register'} == 0;

    return $conf->{$self->{'primary_key'}} unless ref $self->{'primary_key'};

    unless($full) {
        return $self->{'name'} if defined $self->{'name'};
    }

    # multiple primary keys
    if(ref $self->{'primary_key'}->[1] eq '') {
        my @keys;
        for my $key (@{$self->{'primary_key'}}) {
            push @keys, $conf->{$key} if defined $conf->{$key};
        }
        push @keys, $self->{'name'} if defined $self->{'name'};
        return \@keys;
    }

    # secondary keys
    my $primary = $self->{'name'} || $conf->{$self->{'primary_key'}->[0]};

    return $primary unless $full;
    my $secondary = [];
    for my $key (@{$self->{'primary_key'}->[1]}) {
        next unless defined $conf->{$key};
        push @{$secondary}, [ $key, $conf->{$key} ];
    }
    return([$primary, $secondary]);
}


##########################################################

=head2 get_long_name

return the objects name plus alias

=cut
sub get_long_name {
    my $self = shift;
    my $name =  $self->get_name();
    if(defined $self->{'conf'}->{'alias'} and $self->{'conf'}->{'alias'} ne $name) {
        return $name." - ".$self->{'conf'}->{'alias'};
    }
    return $name;
}


##########################################################

=head2 get_sorted_keys

return the sorted config keys for this object

=cut
sub get_sorted_keys {
    my $self = shift;
    my $conf = shift || $self->{'conf'};
    my @keys;
    if(ref $conf eq 'HASH') {
        @keys = keys %{$conf};
    } else {
        @keys = @{$conf};
    }
    @keys = sort _sort_by_object_keys @keys;
    return \@keys;
}


##########################################################

=head2 get_computed_config

return computed config for this object

=cut
sub get_computed_config {
    my $self    = shift;
    my $objects = shift;

    my $cache = $self->{'cache'}->{'computed'}->{$self->{'id'}};
    return(@{$cache}) if defined $cache;

    my $conf = dclone($self->{'conf'});
    my $templates = $self->get_used_templates($objects);
    for my $tname (@{$templates}) {
        my $t = $objects->get_template_by_name($self->{'type'}, $tname);
        if(defined $t) {
            for my $key (keys %{$t->{'conf'}}) {
                if( !defined $conf->{$key} ) {
                    $conf->{$key} = $t->{'conf'}->{$key};
                }
                elsif( defined $self->{'default'}->{$key}
                      and $self->{'default'}->{$key}->{'type'} eq 'LIST'
                      and substr($t->{'conf'}->{$key}->[0], 0, 1) eq '+'
                ) {
                        # merge uniq list elements together
                        my $list         = dclone($t->{'conf'}->{$key});
                        $list->[0]       = substr($list->[0], 1);
                        $conf->{$key}    = [] unless defined $conf->{$key};
                        @{$conf->{$key}} = sort @{Thruk::Utils::array_uniq([@{$list}, @{$conf->{$key}}])};
                }
            }
        }
    }
    delete $conf->{'use'};

    my @keys = sort _sort_by_object_keys keys %{$conf};
    $self->{'cache'}->{'computed'}->{$self->{'id'}} = [\@keys, $conf];
    return(\@keys, $conf);
}


##########################################################

=head2 get_default_keys

return the sorted default keys for this object

=cut
sub get_default_keys {
    my $self = shift;
    my $categories = {};
    for my $key (keys %{$self->{'default'}}) {
        next if $self->{'default'}->{$key}->{'type'} eq 'DEPRECATED';
        next if $self->{'default'}->{$key}->{'type'} eq 'ALIAS';
        my $cat = $self->{'default'}->{$key}->{'cat'} || 'Misc';
        $categories->{$cat} = [] unless defined $categories->{$cat};
        push @{$categories->{$cat}}, $key;
    }

    my @result;
    for my $cat (sort _sort_by_category_keys keys %{$categories}) {
        my @keys = sort _sort_by_object_keys @{$categories->{$cat}};
        push @result, { name => $cat, keys => \@keys };
    }

    push @result, { name => 'Custom Variables', keys => ['customvariable'] };

    return \@result;
}


##########################################################

=head2 get_help

return the help for given attribute

=cut
sub get_help {
    my $self = shift;
    my $attr = shift;

    return Monitoring::Config::Help::get_config_help($self->{'type'}, $attr);
}


##########################################################

=head2 get_data_from_param

get data hash from post parameter

=cut
sub get_data_from_param {
    my $self     = shift;
    my $param    = shift;
    my $data     = shift || {};
    my $defaults = $self->{'default'};

    my @param_keys;
    my $new_param = {};
    for my $key (sort keys %{$param}) {
        next unless $key =~ m/^obj\./mx;
        my $value = $param->{$key};
        $key =~ s/^obj\.//mx;
        $key =~ s/\.\d+$//mx;

        # remove whitespace
        $key   =~ s/^\s*(.*?)\s*$/$1/gmxo;
        $value =~ s/^\s*(.*?)\s*$/$1/gmxo unless ref $value;

        push @param_keys, $key;
        $new_param->{$key} = $value;
    }

    my %seen = ();
    my @uniq = sort( grep { !$seen{$_}++ } (@param_keys, keys %{$self->{'conf'}}) );
    for my $key (@uniq) {
        my $value = $new_param->{$key};
        next unless defined $value;

        if($self->{'type'} eq 'timeperiod' and $value =~ m/\d{1,2}:\d{1,2}\-\d{1,2}:\d{1,2}/gmx) {
            # add leading zeros to timestamps
            $value =~ s/^(\d):/0$1:/gmx;
            $value =~ s/,\s*(\d):/,0$1:/gmx;
            $value =~ s/\-(\d):/-0$1:/gmx;
            $value =~ s/:(\d)\-/:0$1-/gmx;
            $value =~ s/:(\d)$/:0$1/gmx;
            $value =~ s/,\s*/,/gmx;
        }

        if(!defined $defaults->{$key}) {
            if(substr($key, 0, 1) eq '_') {
                $key = uc $key; # custom vars are all uppercase
                $data->{$key} = $value;
            }
            elsif($self->{'type'} eq 'timeperiod') {
                $data->{$key} = $value;
            }
            next;
        }
        next if $defaults->{$key}->{'type'} eq 'DEPRECATED';

        if( $defaults->{$key}->{'type'} eq 'LIST' ) {
            if(ref $value eq 'ARRAY') {
                $data->{$key} = $value;
            } else {
                my @list = split(/\s*,\s*/mx, $value);
                # remove empty elements
                @list = grep {!/^\s*$/mx} @list;
                $data->{$key} = \@list;
            }
        }
        elsif( $defaults->{$key}->{'type'} eq 'ENUM' ) {
            my @values;
            if(ref $value eq 'ARRAY') {
                @values = @{$value};
            } else {
                @values = split(/\s*,\s*/mx, $value);
            }
            $data->{$key} = [];
            for my $v (@values) {
                next if $v eq 'noop';
                next if $v =~ m/^\s*$/mx;
                push @{$data->{$key}}, $v;
            }
        }
        elsif( $defaults->{$key}->{'type'} eq 'COMMAND' ) {
            # when there are arguments, join them with a !
            if($param->{'obj.'.$key.'.2'} !~ m/^\s*$/mx) {
                $data->{$key} = $param->{'obj.'.$key.'.1'}.'!'.$param->{'obj.'.$key.'.2'};
            }
            # just use the command else
            else {
                $data->{$key} = $param->{'obj.'.$key.'.1'};
            }
            delete $param->{$key.'.2'};
        }
        else {
            $data->{$key} = $value;
        }
    }
    return $data;
}


##########################################################

=head2 has_object_changed

check if there are any differences between this object and a reference object

=cut
sub has_object_changed {
    my $self = shift;
    my $data = shift;

    my %seen = ();
    my @uniq = sort( grep { !$seen{$_}++ } (keys %{$data}, keys %{$self->{'conf'}}) );

    for my $key (@uniq) {
        return 1 if !defined $data->{$key};
        return 1 if !defined $self->{'conf'}->{$key};

        my $test1 = $data->{$key};
        if(ref $test1 eq 'ARRAY') { $test1 = join(',', @{$test1}) }

        my $test2 = $self->{'conf'}->{$key};
        if(ref $test2 eq 'ARRAY') { $test2 = join(',', @{$test2}) }

        return 1 if $test1 ne $test2;
    }
    return;
}


##########################################################

=head2 get_used_templates

return all recursive used templates

=cut
sub get_used_templates {
    my $self    = shift;
    my $objects = shift;
    my $lvl     = shift || 0;

    my @templates;
    return \@templates unless defined $self->{'conf'}->{'use'};

    # avoid deep recursion
    return \@templates if $lvl > 50;

    my $cat  = $self->{'type'};

    for my $template (@{$self->{'conf'}->{'use'}}) {
        push @templates, $template;
        my $tmpl = $objects->get_template_by_name($cat, $template);
        if(defined $tmpl) {
            push @templates, @{$tmpl->get_used_templates($objects, ++$lvl)};
        }
    }
    return \@templates;
}


##########################################################

=head2 get_resolved_config

returns config hash with templates resolved

=cut
sub get_resolved_config {
    my $self    = shift;
    my $objects = shift;

    confess("no objects") unless defined $objects;

    return $self->{'conf'} unless defined $self->{'conf'}->{'use'};

    my $conf = {};
    for my $key (keys %{$self->{'conf'}}) {
        next if $key eq 'use';
        $conf->{$key} = $self->{'conf'}->{$key};
    }

    # add resolved templates
    for my $tname (@{$self->{'conf'}->{'use'}}) {
        my $tmpl;
        my $tpl_id = $objects->{'byname'}->{'templates'}->{$self->get_type()}->{$tname};
        if(defined $tpl_id) {
            $tmpl = $objects->{'byid'}->{$tpl_id};
        }
        if(defined $tmpl) {
            my $tpl_conf = $tmpl->get_resolved_config($objects);
            for my $key (keys %{$tpl_conf}) {
                next if defined $conf->{$key};
                next if $key eq 'register';
                next if $key eq 'name';
                $conf->{$key} = $tpl_conf->{$key};
            }
        }
    }

    return $conf;
}


##########################################################

=head2 set_uniq_id

sets a uniq id

=cut
sub set_uniq_id {
    my $self    = shift;
    my $objects = shift;

    if(!defined $self->{'id'} or $self->{'id'} eq 'new') {
        $self->{'id'} = $self->_make_id();
    }

    # make sure id is uniq
    my $nr = 5;
    while(defined $objects->{'byid'}->{$self->{'id'}} and $objects->{'byid'}->{$self->{'id'}} != $self) {
        $self->{'id'} = $self->_make_id(++$nr);
    }
    return $self->{'id'};
}


##########################################################

=head2 _sort_by_object_keys

sort function for object keys

=cut
sub _sort_by_object_keys {

    my $num = 30;
    my $order = [
        "name",
        "service_description",
        "host_name",
        "timeperiod_name",
        "contact_name",
        "contactgroup_name",
        "hostgroup_name",
        "servicegroup_name",
        "command_name",
        "alias",
        "use",
        "monday",
        "tuesday",
        "wednesday",
        "thursday",
        "friday",
        "saturday",
        "sunday",
        "module_name",
        "module_type",
        "path",
        "args",
    ];
    for my $ord (@{$order}) {
        if($a eq $ord) { return -$num; }
        if($b eq $ord) { return  $num; }
        $num--;
    }

    my $result = $a cmp $b;

    if(substr($a, 0, 1) eq '_' and substr($b, 0, 1) eq '_') {
        return $result;
    }
    if(substr($a, 0, 1) eq '_') { return -$result; }
    if(substr($b, 0, 1) eq '_') { return -$result; }

    return $result;
}


##########################################################

=head2 _sort_by_category_keys

sort function for category keys

=cut
sub _sort_by_category_keys {

    my $num = 20;
    my $order = [
        "Basic",
        "Extended",
        "Checks",
        "Contacts",
        "Notifications",
        "Ext Info",
        "Flapping",
        "Map",
        "Misc",
    ];
    for my $ord (@{$order}) {
        if($a eq $ord) { return -$num; }
        if($b eq $ord) { return  $num; }
        $num--;
    }

    return $a cmp $b;
}


##########################################################

=head2 _make_id

return a uniq id for this object

=cut
sub _make_id {
    my $self   = shift;
    my $length = shift || 5;

    my $digest = substr(md5_hex($self->{'file'}->{'path'}.':'.$self->{'line'}), 0, $length);

    return $digest;
}


##########################################################

=head1 AUTHOR

Sven Nierlein, 2011, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
