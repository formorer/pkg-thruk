package Monitoring::Config;

use strict;
use warnings;
use Carp qw/cluck/;
use Monitoring::Config::File;
use Data::Dumper;

=head1 NAME

Monitoring::Config - Thruks Object Database

=head1 DESCRIPTION

Provides access to core objects like hosts, services etc...

=head1 METHODS

=cut


##########################################################

=head2 new

    new($config)

return new objects database

=cut
sub new {
    my $class  = shift;
    my $config = shift;

    my $self = {
        'config'             => $config,
        'errors'             => [],
        'parse_errors'       => [],
        'files'              => [],
        'initialized'        => 0,
        'cached'             => 0,
        'needs_update'       => 0,
        'needs_commit'       => 0,
        'last_changed'       => 0,
        'needs_index_update' => 0,
        'coretype'           => 'nagios',
        'cache'              => {},
    };

    bless $self, $class;

    return $self;
}


##########################################################

=head2 init

    init($config, [ $stats ])

initialize configs

=cut
sub init {
    my $self   = shift;
    my $config = shift;
    my $stats  = shift;

    $self->{'stats'} = $stats if defined $stats;

    # update readonly config
    $self->{'config'}->{'obj_readonly'} = $config->{'obj_readonly'};

    return $self unless $self->{'initialized'} == 0;
    $self->{'initialized'} = 1;

    for my $key (keys %{$config}) {
        $self->{'config'}->{$key} = $config->{$key};
    }
    $self->update();
    $self->{'cached'}      = 0;

    # set default excludes when defined manual paths
    if(!defined $self->{'config'}->{'obj_exclude'}
       and !$self->{'config'}->{'core_conf'}) {
        $self->{'config'}->{'obj_exclude'} = [
                    '^cgi.cfg$',
                    '^resource.cfg$',
                    '^nagios.cfg$',
                    '^icinga.cfg$'
        ];
    }

    return $self;
}


##########################################################

=head2 commit

    commit()

Commit changes to disk. Returns 1 on success.

=cut
sub commit {
    my $self = shift;
    my $rc   = 1;
    my $changed_files = $self->get_changed_files();
    for my $file (@{$changed_files}) {
        unless($file->save()) {
            $rc = 0;
        }
    }

    # remove deleted files from files
    my @new_files;
    for my $f (@{$self->{'files'}}) {
        if(!$f->{'deleted'} or -f $f->{'path'}) {
            push @new_files, $f;
        }
    }
    $self->{'files'}        = \@new_files;
    if($rc == 1) {
        $self->{'needs_commit'} = 0;
        $self->{'last_changed'} = time() if scalar @{$changed_files} > 0;
    }

    $self->_collect_errors();

    return $rc;
}


##########################################################

=head2 get_files

    get_files()

Get all files. Returns list of L<Monitoring::Config::File|Monitoring::Config::File> objects.

=cut
sub get_files {
    my $self = shift;
    return $self->{'files'};
}


##########################################################

=head2 get_file_by_path

    get_file_by_path($path)

Get file by path. Returns L<Monitoring::Config::File|Monitoring::Config::File> object or undef.

=cut
sub get_file_by_path {
    my $self = shift;
    my $path = shift;
    for my $file (@{$self->{'files'}}) {
        return $file if $file->{'path'} eq $path;
    }
    return;
}


##########################################################

=head2 get_changed_files

    get_changed_files()

Get all changed files. Returns list of L<Monitoring::Config::File|Monitoring::Config::File> objects.

=cut
sub get_changed_files {
    my $self = shift;
    my @files;
    for my $file (@{$self->{'files'}}) {
        push @files, $file if $file->{'changed'} == 1;
    }
    return \@files;
}


##########################################################

=head2 get_objects

    $list = get_objects()

Get all objects. Returns list of L<Monitoring::Config::Object|Monitoring::Config::Object> objects.

=cut
sub get_objects {
    my $self = shift;
    my @objects = values %{$self->{'objects'}->{'byid'}};
    return \@objects;
}


##########################################################

=head2 get_objects_by_type

    $list = get_objects_by_type($type, [ $filter ])

Returns list of L<Monitoring::Config::Object|Monitoring::Config::Object> objects for a type.

=cut
sub get_objects_by_type {
    my $self   = shift;
    my $type   = shift;
    my $filter = shift;

    return [] unless defined $self->{'objects'}->{'byname'}->{$type};

    if(defined $filter) {
        if(defined $self->{'objects'}->{'byname'}->{$type}->{$filter}) {
            return $self->{'objects'}->{'byname'}->{$type}->{$filter};
        }
        return;
    }

    my $objs = [];
    for my $id (@{$self->{'objects'}->{'bytype'}->{$type}}) {
        my $obj = $self->get_object_by_id($id);
        die($id) unless defined $obj;
        push @{$objs}, $obj;
    }

    return $objs;
}


##########################################################

=head2 get_objects_by_name

    get_objects_by_name($type, $name, [ $templates_only , [ $name2 ]])

Get objects by name. Returns list of L<Monitoring::Config::Object|Monitoring::Config::Object> objects.

=cut
sub get_objects_by_name {
    my $self           = shift;
    my $type           = shift;
    my $name           = shift;
    my $templates_only = shift || 0;
    my $name2          = shift;

    # object with secondary name
    if(defined $name2 and $name2 ne '') {
        my $subtype;
        ($subtype,$name2) = split/:/mx, $name2, 2;
        my $objects = $self->get_objects_by_type($type, $name);
        my $id;
        if($subtype eq 'ho') {
            $id = $objects->{'host_name'}->{$name2};
        } elsif($subtype eq 'hg') {
            $id = $objects->{'hostgroup_name'}->{$name2};
        }
        if(defined $id) {
            my $obj = $self->get_object_by_id($id);
            confess("corrupt objects") unless defined $obj;
            return [$obj];
        }
        return [];
    }

    # existing template
    my $objs = {};
    my $tid  = $self->{'objects'}->{'byname'}->{'templates'}->{$type}->{$name};
    if(defined $tid) {
        my $obj = $self->get_object_by_id($tid);
        confess("corrupt objects") unless defined $obj;
        $objs->{$tid} = $obj;
    }

    # existing object
    unless($templates_only) {
        if(defined $self->{'objects'}->{'byname'}->{$type}->{$name}) {
            my $id = $self->{'objects'}->{'byname'}->{$type}->{$name};
            unless(ref $id) {
                my $obj = $self->get_object_by_id($id);
                confess("corrupt objects") unless defined $obj;
                $objs->{$id} = $obj;
            } else {
                for my $subtype (keys %{$id}) {
                    for my $subid (values %{$id->{$subtype}}) {
                        my $obj = $self->get_object_by_id($subid);
                        confess("corrupt objects") unless defined $obj;
                        $objs->{$subid} = $obj;
                    }
                }
            }
        }
    }
    my @objects = values %{$objs};
    return \@objects;
}


##########################################################

=head2 get_templates_by_type

    get_templates_by_type($type)

Get templates by type. Returns list of L<Monitoring::Config::Object|Monitoring::Config::Object> objects.

=cut
sub get_templates_by_type {
    my $self   = shift;
    my $type   = shift;

    return [] unless defined $self->{'objects'}->{'byname'}->{'templates'}->{$type};

    my $objs = [];
    my $ids  = [ values %{$self->{'objects'}->{'byname'}->{'templates'}->{$type}} ];
    for my $id (@{$ids}) {
        push @{$objs}, $self->get_object_by_id($id);
    }
    return $objs;
}


##########################################################

=head2 get_template_by_name

    get_template_by_name($type, $name)

Get template object by name. Returns list of L<Monitoring::Config::Object|Monitoring::Config::Object> objects.

=cut
sub get_template_by_name {
    my $self = shift;
    my $type = shift;
    my $name = shift;

    # existing template
    if(defined $self->{'objects'}->{'byname'}->{'templates'}->{$type}->{$name}) {
        return $self->get_object_by_id($self->{'objects'}->{'byname'}->{'templates'}->{$type}->{$name});
    }

    return;
}

##########################################################

=head2 get_object_by_location

    get_object_by_location($path, $linenr)

Get object by location. Returns L<Monitoring::Config::Object|Monitoring::Config::Object> objects or undef.

=cut
sub get_object_by_location {
    my $self = shift;
    my $path = shift;
    my $line = shift;

    for my $file (@{$self->{'files'}}) {
        next unless $file->{'path'} eq $path;
        for my $obj (@{$file->{'objects'}}) {
            if(defined $obj->{'line'} and defined $obj->{'line2'}
               and $obj->{'line'} ne '' and $obj->{'line2'} ne ''
               and $line >= $obj->{'line'} and $line <= $obj->{'line2'}) {
                return $obj;
            }
        }
    }
    return;
}


##########################################################

=head2 get_object_by_id

    get_object_by_id($id)

Get object by id. Returns L<Monitoring::Config::Object|Monitoring::Config::Object> object or undef.

=cut
sub get_object_by_id {
    my $self = shift;
    my $id   = shift || confess("no id");

    return $self->{'objects'}->{'byid'}->{$id};
}


##########################################################

=head2 get_services_for_host

    get_services_for_host($hostobj)

Get services by host. Returns a hashref with ids of references:

 { host => {}, group => {} }

=cut
sub get_services_for_host {
    my $self    = shift;
    my $host    = shift;

    $self->{'stats'}->profile(begin => "M::C::get_services_for_host()") if defined $self->{'stats'};

    my($host_conf_keys, $host_config) = $host->get_computed_config($self);

    my $services  = { 'host' => {}, 'group' => {}};
    my $host_name = $host->get_name();
    my $groups    = $host->get_groups($self);

    for my $svc (@{$self->get_objects_by_type('service')}) {
        my($svc_conf_keys, $svc_config) = $svc->get_computed_config($self);

        # exclude hosts by !host_name
        if(defined $svc_config->{'host_name'} and grep { $_ eq '!'.$host_name } @{$svc_config->{'host_name'}}) {
            next;
        }

        # exclude hostgroup by !group
        if(defined $svc_config->{'hostgroup_name'}) {
            my $found = 0;
            for my $group (@{$groups}) {
                if(grep { $_ eq '!'.$group } @{$svc_config->{'hostgroup_name'}}) {
                    $found++;
                    last;
                }
            }
            next if $found;
        }

        my $name = $svc->get_name();
        if(defined $name) {
            if(defined $svc_config->{'host_name'} and grep { $_ eq $host_name } @{$svc_config->{'host_name'}}) {
                $services->{'host'}->{$name} = $svc;
            }
            if(defined $svc_config->{'hostgroup_name'}) {
                for my $group (@{$groups}) {
                    if(grep { $_ eq $group} @{$svc_config->{'hostgroup_name'}}) {
                        $services->{'group'}->{$name} = {'svc' => $svc, 'groups' => [] } unless defined $services->{'group'}->{$name};
                        push @{$services->{'group'}->{$name}->{'groups'}}, $group;
                        last;
                    }
                }
            }
        }
    }

    $self->{'stats'}->profile(end => "M::C::get_services_for_host()") if defined $self->{'stats'};

    return $services;
}


##########################################################

=head2 update

    update()

update objects config

=cut
sub update {
    my ( $self ) = @_;

    $self->{'needs_commit'} = 0;
    $self->{'needs_update'} = 0;
    $self->{'last_changed'} = 0;

    $self->_reset_errors(1);
    $self->_set_config();
    $self->_set_files();
    $self->_read_objects();
    return 1;
}


##########################################################

=head2 check_files_changed

    check_files_changed([ $reload ])

update objects config

=cut
sub check_files_changed {
    my $self   = shift;
    my $reload = shift || 0;

    # reset errors
    $self->_reset_errors();
    my $errors1 = scalar @{$self->{'errors'}};

    $self->{'needs_update'} = 0;
    $self->{'last_changed'} = 0 if $reload;

    if($self->{'_corefile'} and $self->_check_file_changed($self->{'_corefile'})) {
        # maybe core type has changed
        $self->_set_coretype();
    }

    $self->_check_files_changed($reload);
    my $errors2 = scalar @{$self->{'errors'}};

    if($errors2 > $errors1) {
        $self->{'needs_update'} = 1;
    }
    if($reload or $self->{'needs_index_update'}) {
        $self->{'needs_update'} = 0;
        $self->update();
    }
    return 1;
}


##########################################################

=head2 update_object

    update_object($obj, $newdata, [ $comments, [ $rebuild ]])

update objects config

=cut
sub update_object {
    my $self    = shift;
    my $obj     = shift;
    my $data    = shift;
    my $comment = shift || '';
    my $rebuild = shift;
    $rebuild = 1 unless defined $rebuild;

    return unless defined $obj;

    my $oldname = $obj->get_name();

    # reset errors
    $self->_reset_errors();

    my $file = $obj->{'file'};

    # delete some references
    $self->delete_object($obj, 0);

    # update object
    $obj->{'conf'}          = $data;
    $obj->{'cache'}         = {};
    $obj->{'comments'}      = [ split/\n/mx, $comment ];
    $file->{'changed'}      = 1;
    $self->{'needs_commit'} = 1;

    push @{$file->{'objects'}}, $obj;

    my $newname = $obj->get_name();

    if(defined $oldname and defined $newname and $oldname ne $newname) {
        $self->rename_dependencies($obj, $oldname, $newname);
    }

    $self->_rebuild_index() if $rebuild;

    return 1;
}


##########################################################

=head2 delete_object

    delete_object($obj, [ $rebuild ])

update objects config

=cut
sub delete_object {
    my $self    = shift;
    my $obj     = shift;
    my $rebuild = shift;
    $rebuild    = 1 unless defined $rebuild;

    my $file                = $obj->{'file'};
    $file->{'changed'}      = 1;
    $self->{'needs_commit'} = 1;

    # remove object from file
    my @new_objects;
    for my $o (@{$file->{'objects'}}) {
        next if $o eq $obj;
        push @new_objects, $o;
    }
    $file->{'objects'} = \@new_objects;

    $self->_rebuild_index() if $rebuild;

    return 1;
}


##########################################################

=head2 move_object

    move_object($obj, $newfile, [ $rebuild ])

move object to different file

=cut
sub move_object {
    my $self    = shift;
    my $obj     = shift;
    my $newfile = shift;
    my $rebuild = shift;
    $rebuild    = 1 unless defined $rebuild;

    return unless defined $newfile;
    return unless defined $obj;

    my $file                = $obj->{'file'};
    $file->{'changed'}      = 1;
    $newfile->{'changed'}   = 1;
    $self->{'needs_commit'} = 1;

    $self->delete_object($obj, 1);

    $obj->{'line'} = 0; # put new object at the end
    push @{$newfile->{'objects'}}, $obj;

    $self->_rebuild_index() if $rebuild;

    return 1;
}


##########################################################

=head2 file_add

    file_add($file, [ $rebuild ])

add new file to config

=cut
sub file_add {
    my $self    = shift;
    my $file    = shift;
    my $rebuild = shift;
    $rebuild    = 1 unless defined $rebuild;
    push @{$self->{'files'}}, $file;
    $self->_rebuild_index() if $rebuild;
    return;
}


##########################################################

=head2 file_delete

    file_delete($file, [ $rebuild ])

remove a file from the config

=cut
sub file_delete {
    my $self    = shift;
    my $file    = shift;
    my $rebuild = shift;
    $rebuild                = 1 unless defined $rebuild;
    $file->{'deleted'}      = 1;
    $file->{'changed'}      = 1;
    $self->{'needs_commit'} = 1;

    $self->_rebuild_index() if $rebuild;
    return;
}


##########################################################

=head2 file_undelete

    file_undelete($file, [ $rebuild ])

undelete a file marked for removal

=cut
sub file_undelete {
    my $self    = shift;
    my $file    = shift;
    my $rebuild = shift;

    $rebuild                = 1 unless defined $rebuild;
    $file->{'deleted'}      = 0;
    $file->{'changed'}      = 1;
    $self->{'needs_commit'} = 1;

    $self->_rebuild_index() if $rebuild;
    return;
}


##########################################################

=head2 rename_dependencies

    rename_dependencies($obj, $oldname, $newname)

rename dependencies

=cut
sub rename_dependencies {
    my($self, $object, $old, $new) = @_;
    my $refs = $self->get_references($object, $old);

    # replace references in other objects
    for my $t (keys %{$refs}) {
        for my $oid (keys %{$refs->{$t}}) {
            my $obj = $self->get_object_by_id($oid);
            if($obj->{'file'}->{'readonly'}) {
                push @{$self->{'errors'}}, "could not update dependency in read-only file: ".$obj->{'file'}->{'path'};
                next;
            }
            for my $key (keys %{$refs->{$t}->{$oid}}) {
                if($obj->{'default'}->{$key}->{'type'} eq 'STRING') {
                    my $m2 = "$obj->{'conf'}->{$key}";
                    my $pre = substr($m2, 0, 1);
                    if($pre eq '!' or $pre eq '+') { $m2 = substr($m2, 1); } else { $pre = ''; }
                    $obj->{'conf'}->{$key} = $pre.$new;
                }
                elsif($obj->{'default'}->{$key}->{'type'} eq 'LIST') {
                    my $x = 0;
                    for my $m (@{$obj->{'conf'}->{$key}}) {
                        my $m2 = "$m";
                        $x++;
                        my $pre = substr($m2, 0, 1);
                        if($pre eq '!' or $pre eq '+') { $m2 = substr($m2, 1); } else { $pre = ''; }
                        next unless $m2 eq $old;
                        $obj->{'conf'}->{$key}->[$x-1] = $pre.$new;
                    }
                }
                elsif($obj->{'default'}->{$key}->{'type'} eq 'COMMAND') {
                    my($cmd,$arg) = split(/!/mx, $obj->{'conf'}->{$key}, 2);
                    if(!defined $arg or $arg eq '') {
                        $obj->{'conf'}->{$key} = $new;
                    } else {
                        $obj->{'conf'}->{$key} = $new.'!'.$arg;
                    }
                }
                else {
                    confess("replace for ".$obj->{'default'}->{$key}->{'type'}." not implemented");
                }
            }
            $obj->{'file'}->{'changed'} = 1;
        }
    }

    return;
}

##########################################################

=head2 get_references

    get_references($obj, [ $name ])

return all references for this object

=cut
sub get_references {
    my($self, $obj, $name) = @_;
    $name = $obj->get_name() unless defined $name;

    my $type = $obj->get_type();
    my $list = {};

    # create list of types with that reference
    my $refs = {};
    for my $t (@{$Monitoring::Config::Object::Types}) {
        my $obj = Monitoring::Config::Object->new(type => $t, coretype => $self->{'coretype'});
        for my $key (keys %{$obj->{'default'}}) {
            next unless defined $obj->{'default'}->{$key}->{'link'};
            next unless $obj->{'default'}->{$key}->{'link'} eq $type;
            $refs->{$t}->{$key} = 0;
        }
    }

    # gather references in all objects
    for my $obj (@{$self->get_objects()}) {
        my $t = $obj->get_type();
        next unless defined $refs->{$t};
        for my $key (keys %{$refs->{$t}}) {
            next unless defined $obj->{'conf'}->{$key};
            if($obj->{'default'}->{$key}->{'type'} eq 'STRING') {
                next unless $obj->{'conf'}->{$key} eq $name;
                $list->{$t}->{$obj->get_id()}->{$key} = 1;
            }
            elsif($obj->{'default'}->{$key}->{'type'} eq 'LIST') {
                my $x = 0;
                for my $m (@{$obj->{'conf'}->{$key}}) {
                    my $m2  = "$m";
                    my $pre = substr($m2, 0, 1);
                    if($pre eq '!' or $pre eq '+') { $m2 = substr($m2, 1); }
                    next unless $m2 eq $name;
                    $list->{$t}->{$obj->get_id()}->{$key} = $x;
                    $x++;
                }
            }
            elsif($obj->{'default'}->{$key}->{'type'} eq 'COMMAND') {
                my($cmd,$arg) = split(/!/mx, $obj->{'conf'}->{$key}, 2);
                next if $cmd ne $name;
                $list->{$t}->{$obj->get_id()}->{$key} = 0;
            }
            else {
                confess("reference for ".$obj->{'default'}->{$key}->{'type'}." not implemented");
            }
        }
    }


    return $list;
}

##########################################################

=head2 get_default_keys

    get_default_keys($type, [ $options ])

 $options = {
     no_alias => 0,   # skip alias definitions
 }

return the sorted default config keys for a type of object

=cut
sub get_default_keys {
    my($self,$type, $options) = @_;
    $options = {} unless defined $options;
    $options->{'no_alias'} = 0 unless defined $options->{'no_alias'};
    my $obj = Monitoring::Config::Object->new(type     => $type,
                                              coretype => $self->{'coretype'});
    my @keys;
    for my $key (keys %{$obj->{'default'}}) {
        next if $options->{'no_alias'} == 1 and $obj->{'default'}->{$key}->{'type'} eq 'ALIAS';
        next if $obj->{'default'}->{$key}->{'type'} eq 'DEPRECATED';
        push @keys, $key;
    }
    return \@keys;
}


##########################################################
# INTERNAL SUBS
##########################################################
sub _set_config {
    my $self  = shift;

    if($self->{'config'}->{'core_conf'}) {
        $self->{'config'}->{'obj_file'}          = [];
        $self->{'config'}->{'obj_dir'}           = [];
        $self->{'config'}->{'obj_resource_file'} = undef;

        my $core_conf = $self->{'config'}->{'core_conf'};
        if(defined $ENV{'OMD_ROOT'} and -s $ENV{'OMD_ROOT'}."/version") {
            my $newest = $self->_newest_file(
                                             $ENV{'OMD_ROOT'}.'/tmp/nagios/nagios.cfg',
                                             $ENV{'OMD_ROOT'}.'/tmp/icinga/icinga.cfg',
                                             $ENV{'OMD_ROOT'}.'/tmp/icinga/nagios.cfg',
                                             $ENV{'OMD_ROOT'}.'/tmp/shinken/shinken.cfg',
                                            );
            $core_conf = $newest if defined $newest;
        }

        if($core_conf =~ m|/omd/sites/(.*?)/etc/nagios/nagios.cfg|mx) {
            $core_conf = '/omd/sites/'.$1.'/tmp/nagios/nagios.cfg';
        }
        elsif($core_conf =~ m|/omd/sites/(.*?)/etc/icinga/icinga.cfg|mx) {
            $core_conf = '/omd/sites/'.$1.'/tmp/icinga/icinga.cfg' if -e '/omd/sites/'.$1.'/tmp/icinga/icinga.cfg';
            $core_conf = '/omd/sites/'.$1.'/tmp/icinga/nagios.cfg' if -e '/omd/sites/'.$1.'/tmp/icinga/nagios.cfg';
        }
        elsif($core_conf =~ m|/omd/sites/(.*?)/etc/shinken/shinken.cfg|mx) {
            $core_conf = '/omd/sites/'.$1.'/tmp/shinken/shinken.cfg';
        }

        $self->_update_core_conf($core_conf);
    }

    $self->_set_coretype();

    return;
}


##########################################################
sub _update_core_conf {
    my $self      = shift;
    my $core_conf = shift;

    if(!defined $self->{'_coreconf'} or $self->{'_coreconf'} ne $core_conf) {
        if($core_conf) {
            $self->{'_corefile'} = Monitoring::Config::File->new($core_conf, $self->{'config'}->{'obj_readonly'}, $self->{'coretype'});
        } else {
            $self->{'_corefile'} = undef;
            return;
        }
    }
    $self->{'_coreconf'} = $core_conf;

    my $basedir = $core_conf;
    $basedir =~ s/\/[^\/]*?$//mx;

    open(my $fh, '<', $core_conf) or do {
        push @{$self->{'errors'}}, "cannot read $self->{'_coreconf'}: $!";
        $self->{'initialized'} = 0;
        return;
    };
    $self->{'_corefile'}->{'conf'} = {};
    while(my $line = <$fh>) {
        chomp($line);
        my($key,$value) = split/\s*=\s*/mx, $line, 2;
        next unless defined $value;
        $key   =~ s/^\s*(.*?)\s*$/$1/mx;
        $value =~ s/^\s*(.*?)\s*$/$1/mx;

        if(defined $self->{'_corefile'}->{'conf'}->{$key}) {
            if(ref $self->{'_corefile'}->{'conf'}->{$key} eq '') {
                my $values = [ $self->{'_corefile'}->{'conf'}->{$key} ];
                $self->{'_corefile'}->{'conf'}->{$key} = $values;
            }
            push @{$self->{'_corefile'}->{'conf'}->{$key}}, $value;
        } else {
            $self->{'_corefile'}->{'conf'}->{$key} = $value;
        }

        if($key eq 'cfg_file') {
            push @{$self->{'config'}->{'obj_file'}}, $self->_resolve_relative_path($value, $basedir);
        }
        if($key eq 'cfg_dir') {
            push @{$self->{'config'}->{'obj_dir'}}, $self->_resolve_relative_path($value, $basedir);
        }
        if($key eq 'resource_file') {
            $self->{'config'}->{'obj_resource_file'} = $self->_resolve_relative_path($value, $basedir);
        }
    }
    Thruk::Utils::IO::close($fh, $self->{'path'}, 1);

    return;
}


##########################################################
sub _set_coretype {
    my $self = shift;

    # fixed value from config
    if(defined $self->{'config'}->{'core_type'} and $self->{'config'}->{'core_type'} ne 'auto') {
        $self->{'coretype'} = $self->{'config'}->{'core_type'};
        return;
    }

    # get core from init script link (omd)
    if(defined $ENV{'OMD_ROOT'}) {
        if(-e $ENV{'OMD_ROOT'}.'/etc/init.d/core') {
            $self->{'coretype'} = readlink($ENV{'OMD_ROOT'}.'/etc/init.d/core');
            return;
        }
    }

    # try to determine core type from main config
    if(defined $self->{'_corefile'} and defined $self->{'_corefile'}->{'conf'}->{'icinga_user'}) {
        $self->{'coretype'} = 'icinga';
        return;
    }

    return;
}


##########################################################
sub _read_objects {
    my ( $self ) = @_;
    $self->_set_objects_from_files();
    $self->_rebuild_index();
    return;
}


##########################################################
sub _set_objects_from_files {
    my ( $self ) = @_;

    for my $file (@{$self->{'files'}}) {
        next if $file->{'deleted'} == 1;
        $file->update_objects();
    }

    return;
}


##########################################################
sub _get_files_for_folder {
    my ( $self, $dir, $match ) = @_;
    my @files;
    $dir =~ s/\/$//gmxo;

    my @tmpfiles;
    opendir(my $dh, $dir) or die("cannot open directory $dir: $!");
    while(my $file = readdir $dh) {
        next if $file eq '.';
        next if $file eq '..';
        push @tmpfiles, $file;
    }
    closedir $dh;

    for my $file (@tmpfiles) {
        # follow sub directories
        if(-d $dir."/".$file."/.") {
            push @files, @{$self->_get_files_for_folder($dir."/".$file, $match)};
        }

        # if its a file, make sure it matches our pattern
        if(defined $match) {
            my $test = $dir."/".$file;
            next unless $test =~ m/$match/mx;
        }

        push @files, $dir."/".$file;
    }

    return \@files;
}


##########################################################
sub _set_files {
    my ( $self ) = @_;
    $self->{'files'} = $self->_get_files();
    return;
}


##########################################################
sub _get_files {
    my ( $self ) = @_;

    my @files;
    my $filenames = $self->_get_files_names();
    for my $filename (@{$filenames}) {
        my $file = Monitoring::Config::File->new($filename, $self->{'config'}->{'obj_readonly'}, $self->{'coretype'});
        if(defined $file) {
            push @files, $file;
        } else {
            warn('got no valid file for: '.$filename);
        }
    }

    return \@files;
}


##########################################################
sub _get_files_names {
    my ( $self ) = @_;
    my $files    = {};
    my $config   = $self->{'config'};

    # single folders
    if(defined $config->{'obj_dir'}) {
        for my $dir ( ref $config->{'obj_dir'} eq 'ARRAY' ? @{$config->{'obj_dir'}} : ($config->{'obj_dir'}) ) {
            for my $file (@{$self->_get_files_for_folder($dir, '\.cfg$')}) {
                $files->{$file} = 1;
            }
        }
    }

    # exclude some files?
    # exclude happens before obj_file to make it possible to
    # specify files even if they match an exclude
    if(defined $config->{'obj_exclude'}) {
        for my $ex ( ref $config->{'obj_exclude'} eq 'ARRAY' ? @{$config->{'obj_exclude'}} : ($config->{'obj_exclude'}) ) {
            for my $file (keys %{$files}) {
                if($file =~ m/$ex/gmx) {
                    delete $files->{$file};
                }
            }
        }
    }

    # single files
    if(defined $config->{'obj_file'}) {
        for my $file ( ref $config->{'obj_file'} eq 'ARRAY' ? @{$config->{'obj_file'}} : ($config->{'obj_file'}) ) {
            $files->{$file} = 1;
        }
    }

    if(!defined $config->{'obj_dir'} and !defined $config->{'obj_file'}) {
        push @{$self->{'parse_errors'}}, "you need to configure paths (obj_dir, obj_file)";
    }

    my @uniqfiles = keys %{$files};
    return \@uniqfiles;
}


##########################################################
sub _check_files_changed {
    my $self   = shift;
    my $reload = shift || 0;

    my $oldfiles = {};
    my @newfiles;
    for my $file ( @{$self->{'files'}} ) {

        # don' report newly added files as deleted
        if($file->{'is_new_file'}) {
            push @newfiles, $file;
            next;
        }

        $oldfiles->{$file->{'path'}} = 1;
        my $check = $self->_check_file_changed($file);

        if($check == 1) {
            if(!$reload or $file->{'changed'}) {
                push @newfiles, $file;
                push @{$self->{'errors'}}, "file ".$file->{'path'}." has been deleted.";
                $self->{'needs_index_update'} = 1;
            }
        }
        elsif($check == 2) {
            if($reload or !$file->{'changed'}) {
                $file->{'parsed'} = 0;
                $file->update_objects();
                $file->_update_meta_data();
                $self->{'needs_index_update'} = 1;
            } else {
                push @{$self->{'errors'}}, "Conflict in file ".$file->{'path'}.". File has been changed on disk and via config tool.";
            }
        }

        # changed or new files still exist
        if($check == 0 or $check == 2) {
            push @newfiles, $file;
        }
    }
    $self->{'files'} = \@newfiles;

    for my $file (@{$self->_get_files_names()}) {
        if(!defined $oldfiles->{$file}) {
            push @{$self->{'files'}}, Monitoring::Config::File->new($file, $self->{'config'}->{'obj_readonly'}, $self->{'coretype'});
            $self->{'needs_index_update'} = 1;
        }
    }

    return;
}


##########################################################
# check if file has changed
sub _check_file_changed {
    my $self = shift;
    my $file = shift;

    if(!-f $file->{'path'}) {
        cluck(Dumper($file).": $!");
    }

    # mtime & inode
    my($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
       $atime,$mtime,$ctime,$blksize,$blocks)
       = stat($file->{'path'});

    if(!defined $ino) {
        return 1;
    }
    else {
        # inode or mtime changed?
        if($file->{'inode'} ne $ino or $file->{'mtime'} ne $mtime) {
            $file->{'inode'} = $ino;
            $file->{'mtime'} = $mtime;
            # get md5
            my $meta = $file->get_meta_data();
            if($meta->{'md5'} ne $file->{'md5'}) {
                return 2;
            }
        }
    }
    return 0;
}


##########################################################
# collect errors from all files
sub _collect_errors {
    my ( $self ) = @_;
    $self->{'parse_errors'} = [];
    for my $file ( @{$self->{'files'}} ) {
        push @{$self->{'errors'}},       @{$file->{'errors'}};
        push @{$self->{'parse_errors'}}, @{$file->{'parse_errors'}};
    }
    return scalar @{$self->{'errors'}} + scalar @{$self->{'parse_errors'}};
}


##########################################################
sub _rebuild_index {
    my ( $self ) = @_;

    $self->{'stats'}->profile(begin => "M::C::_rebuild_index()") if defined $self->{'stats'};

    my $objects_without_primary = [];
    my $macros = {
        'host'    => {},
        'service' => {},
    };
    $self->{'cache'} = {};

    # collect errors from all files
    $self->_collect_errors();

    # sort objects into hash
    my $objects = {};
    for my $file ( @{$self->{'files'}} ) {
        for my $obj ( @{$file->{'objects'}} ) {
            my $found = $self->_update_obj_in_index($objects, $obj);
            push @{$objects_without_primary}, $obj if $found == 0;
        }
        for my $type (qw/host service/) {
            for my $macro (keys %{$file->{'macros'}->{$type}}) {
                $macros->{$type}->{$macro} = 1;
            }
        }
    }

    if(scalar @{$objects_without_primary} > 0) {
        for my $obj (@{$objects_without_primary}) {
            my $conf = $obj->get_resolved_config($objects);
            my $tmp_obj = Monitoring::Config::Object->new(type => $obj->get_type(), conf => $conf, coretype => $self->{'coretype'});
            my $primary = $tmp_obj->get_primary_name();
            if(defined $primary) {
                my $found = $self->_update_obj_in_index($objects, $obj, $primary, $conf);
                if($found == 0) {
                    $objects->{'byname'}->{$obj->{'type'}}->{$primary} = $obj->{'id'};
                }
            } else {
                my $type = $obj->get_type();
                if($type ne 'hostescalation' and $type ne 'serviceescalation' and $type ne 'hostgroup') {
                    push @{$self->{'parse_errors'}}, $obj->get_type()." object has no name in ".Thruk::Utils::Conf::_link_obj($obj);
                }
            }
        }
    }

    $self->{'objects'}            = $objects;
    $self->{'macros'}             = $macros;
    $self->{'needs_index_update'} = 0;

    my $parse_errors = $self->_check_references();
    push @{$self->{'parse_errors'}}, @{$parse_errors} if scalar @{$parse_errors} > 0;

    $self->{'stats'}->profile(end => "M::C::_rebuild_index()") if defined $self->{'stats'};
    return;
}


##########################################################
sub _update_obj_in_index {
    my $self    = shift;
    my $objects = shift;
    my $obj     = shift;
    my $primary = shift;
    my $tmpconf = shift;

    my $pname  = $obj->get_primary_name(1, $tmpconf);
    my $tname  = $obj->get_template_name();
    my $found  = 0;

    # set uniq id
    $obj->set_uniq_id($objects);

    # by id
    $objects->{'byid'}->{$obj->{'id'}} = $obj;

    # by template name
    if(defined $tname) {
        my $existing_id = $objects->{'byname'}->{'templates'}->{$obj->{'type'}}->{$tname};
        if(defined $existing_id and $existing_id eq $obj->{'id'}) {
            my $orig = $self->get_object_by_id($existing_id);
            if(defined $orig) {
                push @{$self->{'parse_errors'}}, "duplicate ".$obj->{'type'}." template definition $tname in ".Thruk::Utils::Conf::_link_obj($obj)."\n  -> already defined in ".Thruk::Utils::Conf::_link_obj($orig);
            } else {
                push @{$self->{'parse_errors'}}, "duplicate ".$obj->{'type'}." template definition $tname in ".Thruk::Utils::Conf::_link_obj($obj);
            }
        }
        $objects->{'byname'}->{'templates'}->{$obj->{'type'}}->{$tname} = $obj->{'id'};
        $found++;
    }

    # by name
    if(defined $pname and ref $pname eq 'ARRAY') {
        # multiple primarys
        if(ref $pname->[1] eq '') {
            for my $primary (@{$pname}) {
                $objects->{'byname'}->{$obj->{'type'}}->{$primary} = $obj->{'id'};
                $found++;
            }
        }

        # secondary keys
        else {
            $pname->[0] = $primary if defined $primary;
            if(defined $pname->[0]) {
                for my $secondary (@{$pname->[1]}) {
                    my $type  = $secondary->[0];
                    my $value = $secondary->[1];
                    for my $v (ref $value eq 'ARRAY' ? @{$value} : [ $value ]) {
                        $objects->{'byname'}->{$obj->{'type'}}->{$pname->[0]}->{$type}->{$v} = $obj->{'id'};
                        $found++;
                    }
                }
            }
        }
    }
    elsif(defined $pname or defined $primary) {
        # single primary key
        $pname = $primary if defined $primary;
        my $existing_id = $objects->{'byname'}->{$obj->{'type'}}->{$pname};
        if(defined $existing_id and $existing_id ne $obj->{'id'}) {
            my $orig = $self->get_object_by_id($existing_id);
            if(!defined $orig) {
                push @{$self->{'parse_errors'}},
                    "duplicate ".$obj->{'type'}." definition $pname in ".Thruk::Utils::Conf::_link_obj($obj);
            } else {
                push @{$self->{'parse_errors'}},
                    "duplicate ".$obj->{'type'}." definition $pname in ".Thruk::Utils::Conf::_link_obj($obj)."\n  -> already defined in ".Thruk::Utils::Conf::_link_obj($orig);
            }
        }
        $objects->{'byname'}->{$obj->{'type'}}->{$pname} = $obj->{'id'};
        $found++;
    }

    if($found or defined $primary) {
        # by type
        if(!defined $obj->{'conf'}->{'register'} or $obj->{'conf'}->{'register'} != 0) {
            push @{$objects->{'bytype'}->{$obj->{'type'}}}, $obj->{'id'};
        }
    }

    return $found;
}


##########################################################
sub _reset_errors {
    my($self,$force) = @_;
    if($force) {
        $self->{'errors'}           = [];
        $self->{'parse_errors'}     = [];
    }
    return;
}


##########################################################
sub _newest_file {
    my($self, @files) = @_;
    my %filelist;
    for my $file (@files) {
        my @stat = stat($file);
        if(defined $stat[9]) {
            $filelist{$stat[9]} = $file;
        }
    }
    my @sorted = sort {$a <=> $b} keys %filelist;
    my $newest = shift @sorted;
    return $filelist{$newest} if defined $newest;
    return;
}


##########################################################
sub _check_references {
    my($self) = @_;
    $self->{'stats'}->profile(begin => "M::C::_check_references()") if defined $self->{'stats'};
    my @parse_errors;
    $self->_all_object_links_callback(sub {
        my($file, $obj, $attr, $link, $val) = @_;
        if($attr eq 'use') {
            if(!defined $self->{'objects'}->{'byname'}->{'templates'}->{$link}->{$val}) {
                push @parse_errors, "referenced template '$val' does not exist in ".Thruk::Utils::Conf::_link_obj($obj);
            }
        }
        elsif(!defined $self->{'objects'}->{'byname'}->{$link}->{$val}) {
            # hostgroups are allowed to have a register 0
            if($link ne 'hostgroup' or !defined $self->{'objects'}->{'byname'}->{'templates'}->{$link}->{$val}) {
                push @parse_errors, 'referenced '.$link." '".$val."' does not exist in ".Thruk::Utils::Conf::_link_obj($obj);
            }
        }
    });

    $self->{'stats'}->profile(end => "M::C::_check_references()") if defined $self->{'stats'};
    return \@parse_errors;
}


##########################################################
sub _check_orphaned_objects {
    my($self) = @_;
    $self->{'stats'}->profile(begin => "M::C::_check_orphaned_objects()") if defined $self->{'stats'};
    my @errors;

    # get build list of objects
    my $all_templates = {};
    my $all_objects   = {};
    for my $type (keys %{$self->{'objects'}->{'byname'}}) {
        next if $type eq 'templates';
        my @values = keys %{$self->{'objects'}->{'byname'}->{$type}};
        for my $v (@values) { $all_objects->{$type}->{$v} = 1; }
    }
    for my $type (keys %{$self->{'objects'}->{'byname'}->{'templates'}}) {
        my @values = keys %{$self->{'objects'}->{'byname'}->{'templates'}->{$type}};
        for my $v (@values) { $all_templates->{$type}->{$v} = 1; }
    }

    $self->_all_object_links_callback(sub {
        my($file, $obj, $attr, $link, $val) = @_;
        if($attr eq 'use') {
            delete $all_templates->{$link}->{$val};
        }
        else {
            delete $all_templates->{$link}->{$val} if $link eq 'hostgroup';
            delete $all_objects->{$link}->{$val};
        }
    });
    for my $type (keys %{$all_templates}) {
        for my $name (keys %{$all_templates->{$type}}) {
            push @errors, $type." template '".$name."' is unused in ".Thruk::Utils::Conf::_link_obj($self->get_object_by_id($self->{'objects'}->{'byname'}->{'templates'}->{$type}->{$name}));
        }
    }
    for my $type (keys %{$all_objects}) {
        next if $type eq 'service';
        next if $type eq 'servicedependency';
        for my $name (keys %{$all_objects->{$type}}) {
            my $obj = $self->get_object_by_id($self->{'objects'}->{'byname'}->{$type}->{$name});
            next if defined $obj->{'conf'}->{'members'};
            push @errors, $type." object '".$name."' is unused in ".Thruk::Utils::Conf::_link_obj($obj);
        }
    }

    $self->{'stats'}->profile(end => "M::C::_check_orphaned_objects()") if defined $self->{'stats'};
    return \@errors;
}


##########################################################
# run callback function for every link
sub _all_object_links_callback {
    my($self, $cb) = @_;

    for my $file ( @{$self->{'files'}} ) {
        for my $obj ( @{$file->{'objects'}} ) {
            for my $key (keys %{$obj->{'conf'}}) {
                next unless defined $obj->{'default'}->{$key};
                next unless defined $obj->{'default'}->{$key}->{'link'};
                my $link = $obj->{'default'}->{$key}->{'link'};
                next if $link eq 'servicemember';
                next if $link eq 'icon';
                if($key eq 'use') {
                    for my $ref (@{$obj->{'conf'}->{$key}}) {
                        my $ref2 = "$ref";
                        if(substr($ref2, 0, 1) eq '!' or substr($ref2, 0, 1) eq '+') { $ref2 = substr($ref2, 1); }
                        next if index($ref2, '*') != -1;
                        next if $ref2 eq '';
                        &$cb($file, $obj, $key, $link, $ref2);
                    }
                }
                elsif($obj->{'default'}->{$key}->{'type'} eq 'STRING') {
                    &$cb($file, $obj, $key, $link, $obj->{'conf'}->{$key});
                }
                elsif($obj->{'default'}->{$key}->{'type'} eq 'LIST') {
                    for my $ref (@{$obj->{'conf'}->{$key}}) {
                        my $ref2 = "$ref";
                        if(substr($ref2, 0, 1) eq '!' or substr($ref2, 0, 1) eq '+') { $ref2 = substr($ref2, 1); }
                        next if index($ref2, '*') != -1;
                        next if $ref2 eq '';
                        &$cb($file, $obj, $key, $link, $ref2);
                    }
                }
                elsif($obj->{'default'}->{$key}->{'type'} eq 'COMMAND') {
                    my($cmd,$args) = split(/!/mx, $obj->{'conf'}->{$key}, 2);
                    &$cb($file, $obj, $key, $link, $cmd);
                }
            }
        }
    }
    return;
}


##########################################################
sub _resolve_relative_path {
    my ($self, $file, $basedir) = @_;
    if($file !~ m|^/|mx) {
        $file = $basedir.'/'.$file;
        $file =~ s|//|/|gmx;
        my $x = 0;
        while( $x < 10 && $file =~ s|/[^/]+/\.\./|/|gmx) { $x++ };
    }
    return $file;
}

##########################################################

=head1 AUTHOR

Sven Nierlein, 2011, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
