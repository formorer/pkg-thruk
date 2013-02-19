package Thruk::Utils::CookieAuth;

=head1 NAME

Thruk::Utils::CookieAuth - Utilities Collection for Cookie Authentication

=head1 DESCRIPTION

Cookie Authentication offers a nice login mask and makes it possible
to logout again.

=cut

use warnings;
use strict;
use Data::Dumper;
use LWP::UserAgent;
use Digest::MD5 qw(md5_hex);
use Thruk::Utils::IO;

##############################################
BEGIN {
    $ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;
    eval {
        # required for new IO::Socket::SSL versions
        require IO::Socket::SSL;
        IO::Socket::SSL->import();
        IO::Socket::SSL::set_ctx_defaults( SSL_verify_mode => 0 );
    };
};

##############################################

=head1 METHODS

=head2 external_authentication

    external_authentication($config, $login, $pass, $address)

verify authentication by external login into external url

return:

    sid  if login was ok
    0    if login failed
   -1    on technical problems

=cut
sub external_authentication {
    my($config, $login, $pass, $address) = @_;
    my $authurl  = $config->{'cookie_auth_restricted_url'};
    my $sdir     = $config->{'tmp_path'}.'/sessions';

    my $netloc   = Thruk::Utils::CookieAuth::get_netloc($authurl);
    my $ua       = get_user_agent();
    # bypass ssl host verfication on localhost
    $ua->ssl_opts('verify_hostname' => 0 ) if($authurl =~ m/^(http|https):\/\/localhost/mx or $authurl =~ m/^(http|https):\/\/127\./mx);
    my $res      = $ua->post($authurl);
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
                    return $sessionid;
                }
            } else {
                print STDERR 'authorization failed for user ', $login,' got rc ', $res->code;
                return 0;
            }
        } else {
            print STDERR 'auth: realm does not match, got ', $realm;
        }
    } else {
        print STDERR 'auth: expected code 401, got ', $res->code, "\n", Dumper($res);
    }
    return -1;
}

##############################################

=head2 verify_basic_auth

    verify_basic_auth($config, $basic_auth)

verify authentication by sending request with basic auth header

=cut
sub verify_basic_auth {
    my($config, $basic_auth, $login) = @_;
    my $authurl  = $config->{'cookie_auth_restricted_url'};

    my $ua = get_user_agent();
    # bypass ssl host verfication on localhost
    $ua->ssl_opts('verify_hostname' => 0 ) if($authurl =~ m/^(http|https):\/\/localhost/mx or $authurl =~ m/^(http|https):\/\/127\./mx);
    $ua->default_header( 'Authorization' => 'Basic '.$basic_auth );
    my $res = $ua->post($authurl);
    if($res->code == 200 and $res->decoded_content =~ m/^OK:\ (.*)$/mx) {
        if($1 eq $login) {
            return 1;
        }
    }
    return 0;
}

##############################################

=head2 get_user_agent

    get_user_agent()

returns user agent used for external requests

=cut
sub get_user_agent {
    Thruk::Utils::load_lwp_curl();
    my $ua = LWP::UserAgent->new;
    $ua->timeout(30);
    $ua->agent("thruk_auth");
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
