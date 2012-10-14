package Thruk::Utils::CookieAuth;

=head1 NAME

Thruk::Utils::CookieAuth - Utilities Collection for Cookie Authentication

=head1 DESCRIPTION

Cookie Authentication offers a nice login mask and makes it possible
to logout again.

=cut

use warnings;
use strict;
use LWP::UserAgent;
use Digest::MD5 qw(md5_hex);
use Thruk::Utils::IO;

##############################################

=head1 METHODS

=head2 external_authentication

    external_authentication($config, $login, $pass, $address)

verify authentication by external login into external url

=cut
sub external_authentication {
    my($config, $login, $pass, $address) = @_;
    my $authurl  = $config->{'cookie_auth_restricted_url'};
    my $netloc   = Thruk::Utils::CookieAuth::get_netloc($authurl);
    my $sdir     = $config->{'tmp_path'}.'/sessions';

    my $success = 0;
    my $ua = get_user_agent();
    my $res = $ua->post($authurl);
    if($res->code == 401) {
        my $realm = $res->header('www-authenticate');
        if($realm =~ m/Basic\ realm=\"([^"]+)\"/mx) {
            $realm = $1;
            $ua->credentials( $netloc, $realm, $login, $pass );
            $res = $ua->post($authurl);
            if($res->code == 200 and $res->request->header('authorization') and $res->decoded_content =~ m/^OK:\ (.*)$/mx) {
                if($1 eq $login) {
                    my $sessionid = md5_hex(rand(1000).time());
                    chomp($sessionid);
                    my $hash = $res->request->header('authorization');
                    $hash =~ s/^Basic\ //mx;
                    my $sessionfile = $sdir.'/'.$sessionid;
                    open(my $fh, '>', $sessionfile) or die('failed to open session file: '.$sessionfile.' '.$!);
                    print $fh join('~~~', $hash, $address, $login), "\n";
                    Thruk::Utils::IO::close($fh, $sessionfile);
                    $success = $sessionid;
                }
            }
        }
    }
    return $success;
}

##############################################

=head2 verify_basic_auth

    verify_basic_auth($config, $basic_auth)

verify authentication by sending request with basic auth header

=cut
sub verify_basic_auth {
    my($config, $basic_auth, $login) = @_;
    my $authurl  = $config->{'cookie_auth_restricted_url'};

    my $success = 0;
    my $ua = get_user_agent();
    $ua->default_header( 'Authorization' => 'Basic '.$basic_auth );
    my $res = $ua->post($authurl);
    if($res->code == 200 and $res->decoded_content =~ m/^OK:\ (.*)$/mx) {
        if($1 eq $login) {
            $success = 1;
        }
    }
    return $success;
}

##############################################

=head2 get_user_agent

    get_user_agent()

returns user agent used for external requests

=cut
sub get_user_agent {
    my $ua = LWP::UserAgent->new;
    $ua->timeout(30);
    $ua->agent("");
    return $ua;
}

##############################################

=head2 clean_session_files

    clean_session_files($url)

clean up session files

=cut
sub clean_session_files {
    my($config) = @_;
    my $sdir    = $config->{'tmp_path'}.'/sessions';
    my $timeout = time() - $config->{'cookie_auth_session_timeout'};
    opendir( my $dh, $sdir) or die "can't opendir '$sdir': $!";
    for my $entry (readdir($dh)) {
        next if $entry eq '.' or $entry eq '..';
        my $file = $sdir.'/'.$entry;
        my($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
           $atime,$mtime,$ctime,$blksize,$blocks) = stat($file);
        if($mtime < $timeout) {
            unlink($file);
        }
    }
    return;
}

##############################################

=head2 get_netloc

    get_netloc($url)

return netloc used by LWP::UserAgent credentials

=cut
sub get_netloc {
    my($url) = @_;
    if($url =~ m/^(http|https):\/\/([^\/:]+)\//mx) {
        my $port = $1 eq 'https' ? 443 : 80;
        my $host = $2;
        $host = $host.':'.$port unless CORE::index($host, ':') != -1;
        return($host);
    }
    return('localhost:80');
}

##############################################

=head1 AUTHOR

Sven Nierlein, 2012, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

##############################################

1;
