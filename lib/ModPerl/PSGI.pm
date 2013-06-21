package ModPerl::PSGI;
# ref: http://search.cpan.org/~miyagawa/PSGI-1.101/PSGI.pod
# ref: https://gist.github.com/gardejo/398635/

use strict;
use warnings;

our $VERSION = '0.01';

use File::Spec           ();
use IO::Handle           ();
use Scalar::Util         ();

use Apache2::Connection  ();
use Apache2::Const -compile => qw(OK);
use Apache2::Log         ();
use Apache2::MPM         ();
use Apache2::RequestIO   ();
use Apache2::RequestRec  ();
use Apache2::RequestUtil ();
use Apache2::Response    ();
use Apache2::ServerRec   ();
use Apache2::ServerUtil  ();
use Apache2::URI         ();
use APR::URI             ();

use constant TRUE           => 1==1;
use constant FALSE          => !TRUE;
use constant IS_THREADED    => Apache2::MPM->is_threaded;
use constant IS_NONBLOCKING => lc(Apache2::MPM->show) =~ /^(?:worker|event)$/;
use constant SERVER_NAME    => Apache2::ServerUtil->server->server_hostname;
use constant SERVER_PORT    => Apache2::ServerUtil->server->port;

my %apps; # cache of apps. filename => psgi_app_coderef

sub new { bless {}, shift }

sub handler :method {
    my $class = (@_ >= 2) ? shift : __PACKAGE__;
    my $r     = shift;
    my $psgi  = $r->dir_config->get('psgi_app');
    return $class->call_app($r, $class->load_app($psgi));
}

# see: Plack::Handler::Apache1. This concept is good for CoW.
sub preload {
    my $class = shift;
    for my $app (@_) {
        $class->load_app($app);
    }
}

# see: Plack::Handler::Apache2#load_app
sub load_app {
    my ($class, $psgi) = @_;
    # cache psgi file to %apps by code-reference.
    return $apps{$psgi} ||= do {
        # see: Plack::Handler::Apache2#load_app comment.
        local $ENV{MOD_PERL};
        delete $ENV{MOD_PERL};
        load_psgi($psgi);
    };
}

# see: Plack::Util#load_psgi
sub load_psgi {
    my $stuff = shift;

    my $file = $stuff =~ /^[a-zA-Z0-9\_\:]+$/ ? class_to_file($stuff) : File::Spec->rel2abs($stuff);
    my $app = _load_sandbox($file);
    die "Error while loading $file: $@" if $@;

    return $app;
}

# see: Plack::Util#class_to_file
sub class_to_file {
    my $class_str = shift;
    $class_str =~ s{::}{/}g;
    return $class_str . ".pm";
}

# see: Plack::Util#_load_sandbox
sub _load_sandbox {
    my $_file = shift;
    my $_package = $_file;
    $_package =~ s/([^A-Za-z0-9_])/sprintf("_%2x", unpack("C", $1))/eg;
    local $0 = $_file; # so FindBin etc. works
    local @ARGV = ();  # Some frameworks might try to parse @ARGV

    #print STDERR "_package=$_package\n";

    # Protect tainted other namespace.
    return eval sprintf <<'END_EVAL', $_package;
package ModPerl::PSGI::Internal::Sandbox::%s;
{
    local $@;
    local $!;
    my $app = do $_file;
    if ( !$app && ( my $error = $@ || $! )) { die $error; }
    $app;
}
END_EVAL
}

sub call_app {
    my $class = shift;
    my $r     = shift;
    my $app   = shift;
    my $headers_in = $r->headers_in;

    my $env = {
        # At first, create minimum environments
        # (Both "Handler" is perl-script or modperl.)
        %ENV,

        # psgi.* variables
        'psgi.version'           => [ 1, 1],
        'psgi.url_scheme'        => ($ENV{HTTPS}||'off') =~ /^(?:on|1)$/i ? 'https' : 'http',
        'psgi.input'             => $r, # AS-IS Apache2::RequestIO#read. (same as Plack::Handler::Apache2)
        'psgi.errors'            => *STDERR,
        'psgi.multithread'       => IS_THREADED,
        'psgi.multiprocess'      => TRUE,
        'psgi.run_once'          => FALSE,
        'psgi.streaming'         => TRUE,
        'psgi.nonblocking'       => IS_NONBLOCKING,

        # psgix.* variables
        'psgix.harakiri'         => TRUE,
        'psgix.cleanup'          => TRUE,
        'psgix.cleanup.handlers' => [],

        # original support by ModPerl::PSGI.
        'psgix.logger'           => sub {
            my $param = shift;
            if ( !$param || ref $param ne 'HASH' ) {
                die qq(psgix.logger gives invalid argument. It expects hashref.);
            }
            my ($level, $message) = @$param{qw/level message/};
            if ( !defined $level || !defined $message ) {
                die qq(psgix.logger's hashref requires keys both "level", "message".);
            }
            $level = 'emerg' if $level eq 'fatal';
            if ( $r->log->can($level) ) {
                $r->log->$level($message);
            }
            else {
                die qq(psgix.logger's "level" value requires which "debug", "warn", "info", "error" or "fatal". level="$level" is invalid.);
            }
        },
    };

    # basic keywords if directive "(Set|Add)Handler" value is "modperl"
    if ( $r->handler() eq 'modperl' ) {
        # PSGI core
        # NOTE: PATH_INFO and SCRIPT_PATH definition is following.
        # NOTE: Is low cost create %ENV call $r->subprocess_env at void context?
        $env->{REQUEST_METHOD}  = $r->method();
        $env->{REQUEST_URI}     = $r->unparsed_uri(); # Is this OK?
        $env->{QUERY_STRING}    = $r->args();
        $env->{HTTP_HOST}       = $r->hostname();
        $env->{SERVER_NAME}     = SERVER_NAME;
        $env->{SERVER_PORT}     = SERVER_PORT;
        $env->{SERVER_PROTOCOL} = ($r->the_request =~ m{\b(HTTP/[01.]+)$})[0]; # HTTP/1.0 or HTTP/1.1

        # PSGI optional
        $env->{REMOTE_ADDR}     = $r->connection->remote_ip(); # or APR::SockAddr remote_addr?

        # alternated psg.* or psgix.* definition
        # - Handler "modperl" is not TIEd STDERR.
        $env->{'psgi.errors'}   = ModPerl::PSGI::Internal::ErrorHandle->new($r);;

        # headers
        while ( my ($key, $value) = each %$headers_in ) {
            $key =~ s/-/_/g;
            $key = uc $key;
            next if $key eq 'CONTENT_TYPE' || $key eq 'CONTENT_LENGTH';
            $env->{"HTTP_$key"} = $value;
        }
    }

    $env->{CONTENT_LENGTH} = $headers_in->{'Content-Length'} || '' if exists $headers_in->{'Content-Length'};
    $env->{CONTENT_TYPE} = $headers_in->{'Content-Type'} || ''     if exists $headers_in->{'Content-Type'};

    if ( exists $env->{CONTENT_LENGTH} && defined $env->{CONTENT_LENGTH} ) {
        $env->{CONTENT_LENGTH} =~ s/,.*//;
    }

    # TODO: Exam APR::URI squeezes multi slashes into one slash.
    my $uri = APR::URI->parse($r->pool, $env->{'psgi.url_scheme'}.'://'.$r->hostname.$r->unparsed_uri);
    $env->{PATH_INFO} = $uri->path; # TODO: same result of URI#path ?
    Apache2::URI::unescape_url($env->{PATH_INFO});

    if ( !defined $env->{PATH_INFO} || 0 == length $env->{PATH_INFO} ) {
        $env->{SCRIPT_NAME} = $r->unparsed_uri;
    }

    # TODO: Need fixup_path ?
    $class->fixup_path($r, $env);

    my $res = $class->run_app($app, $env);

    if (ref $res eq 'ARRAY') {
        _handle_response($r, $res);
    }
    elsif (ref $res eq 'CODE') {
        # for lazy/streaming contents.
        $res->(sub {
            _handle_response($r, shift);
        });
    }
    else {
        die "Bad response $res";
    }

    if (@{ $env->{'psgix.cleanup.handlers'} }) {
        $r->push_handlers(
            PerlCleanupHandler => sub {
                for my $cleanup_handler (@{ $env->{'psgix.cleanup.handlers'} }) {
                    $cleanup_handler->($env);
                }

                if ($env->{'psgix.harakiri.commit'}) {
                    $r->child_terminate;
                }
            },
        );
    }
    else {
        if ($env->{'psgix.harakiri.commit'}) {
            $r->child_terminate;
        }
    }

    return Apache2::Const::OK;
}

# Feature Plack::Hander::Apache2 mechanism.
sub fixup_path {
    my $class = shift;
    my $r     = shift;
    my $env   = shift;

    my $path_info = $env->{PATH_INFO} || '';
    my $location  = $r->location;
    if ( $location eq '/' ) {
        $env->{SCRIPT_NAME} = '';
    }
    elsif ( $path_info =~ s{^($location)/?}{/} ) {
        $env->{SCRIPT_NAME} = $1 || '';
    }
    else {
        $r->server->log_error(
            "Your request path is '$path_info' and it doesn't matech your Location(Match) '$location'. " .
            "This should be due to the configuration error. See perldoc ModPerl::PSGI for details."
        );
    }

    $env->{PATH_INFO} = $path_info;
}

sub _handle_response {
    my ($r, $res) = @_;

    my ($status, $headers, $body) = @{ $res };

    my $modperl_headers_out = ($status >= 200 && $status < 300)
        ? $r->headers_out : $r->err_headers_out;

    # see: Plack::Util#header_iter
    my @headers = @$headers;
    while ( my ($key, $value) = splice @headers, 0, 2 ) {
        if ( lc $key eq 'content-type' ) {
            $r->content_type($value);
        }
        elsif ( lc $key eq 'content-length' ) {
            $r->set_content_length($value);
        }
        else {
            # not ->set for multiple header keys (e.g. Set-Cookie)
            $modperl_headers_out->add( $key => $value );
        }
    }

    # Apache2::Const :http constants fits actuall HTTP statu code number.
    $r->status($status);

    # see: Plack::Util#foreach
    if ( ref $body eq 'ARRAY' ) {
        for my $line (@$body) {
            $r->print($line) if length $line;
        }
    }
    elsif ( Scalar::Util::blessed($body)
            and $body->can('path')
            and my $path = $body->path) {
        $r->sendfile($path);
    }
    elsif (defined $body && Scalar::Util::openhandle($body)) {
        local $/ = \65536 unless ref $/;
        while (defined(my $line = $body->getline)) {
            $r->print($line) if length $line;
        }
        $body->close;
        $r->rflush;
    }
#     else {
#         return ModPerl::PSGI::Internal::ResponseObject->new($r);
#     }

    return TRUE; # This value may be trashed at void context.
}

sub run_app {
    # see: Plack::Util#run_app
    my ($class, $app, $env) = @_;
    return eval { $app->($env) } || do {
        my $body = "Internal Server Error";
        $env->{'psgi.errors'}->print($@);
        [ 500, [ 'Content-Type' => 'text/plain', 'Content-Length' => length($body) ], [ $body ] ];
    };
}

{
    package ModPerl::PSGI::Internal::ErrorHandle;
    sub new {
        my $class = shift;
        my $r     = shift;
        bless { r => $r }, $class;
    }
    sub print {
        my $self = shift;
        $self->{r}->log_error(@_);
    }
}

{
    package ModPerl::PSGI::Internal::ResponseObject;
    sub new {
        my $class = shift;
        my $r     = shift;
        bless { r => $r }, $class;
    }
    # $r is global variable it currently.
    sub write {
        my $self = shift;
        my $r = shift;
        $self->{r}->print(@_);
        $self->{r}->rflush;
    }
    sub close {
        my $self = shift;
        $self->{r}->rflush;
    }
}

1;

__END__

=pod

=encoding utf-8

=head1 NAME

ModPerl::PSGI - Lightweight PSGI adaptor for mod_perl2

=head1 SYNOPSIS

 # e.g. in Location or VirtualHost directive
 <Location /path/to/foo>
   # you chan choice "perl-script" or "modperl" for handler.
   SetHandler perl-script
   PerlResponseHandler ModPerl::PSGI
   PerlSetVar psgi_app /real/path/to/foo/app.psgi
 </Location>

=head1 DESCRIPTION

This module is yet another PSGI implementation on mod_perl2.

This concept likes L<Plack>'s L<Plack::Handler::Apache2>,
but this module has some advantages:

=head2 Many MPM support

L<Plack::Handler::Apache2> supports only prefork MPM
when this document is written.
However L<ModPerl::PSGI> supports "prefork", "worker" and "event".
In future, it will supports rest MPMs e.g. "mpm_winnt".

See L<http://httpd.apache.org/docs/2.4/mpm.html> to know Apache MPM.

=head2 support "modperl" handler offically

You have to set (Add|Set)Handler perl-script on L<Plack::Handler::Apache2>.
ModPerl::PSGI support "(Add|Set)Handler) modperl" offically and
some low cost implementation *perlhaps*.

=head2 Very low dependencies

L<Plack::Handler::Apache2> has L<Plack>'s dependencies.
It is not huge, but it is not few too.
If Your environment has some restriction of module installation,
maybe you can not ignore L<Plack>'s dependencies.

ModPerl::PSGI depends L<ONLY> mod_perl2 and Perl5.8 later core moduels.

=head2 Some process is delegated Apache Portable Runtime (apr)

For example, L<Plack> uses L<URI> and L<URI::Escape> for
URI parsing and processing.
In ModPerl::PSGI, this parsing and processing are delegated
mod_perl API and "Apache Portable Runtime" (APR) API.
Those implementes are C and glued by Perl XS.

=head2 Only on Apache web server

You may know combination of "plackup" and web server(Apache/Nginx)'s
reverse proxy for deploy PSGI app.
However this practice is not only one server about web server.
If you wish to opration that web server is only one,
then this concept is that you are comfortable.

Do you care Apache process size on this approach?
Use L<Apache2::SizeLimit> module for this problem
if it become actual.

For your adovice, any persistent process have no small the problem.
Your operation skill is tried.

=head1 SOME LIMITATION AND NOT EASY POINT

L<Plack> has B<great> modules L<Plack::Request> and L<Plack::Response>.
Those modules takes you to be convenient to treat of PSGI's C<$env>.
But ModPerl::PSGI does not offer similar solution yet.

If you use L<Mojolicious>, It have full function, e.g.
L<Mojo::Message::Request>.

=head1 TODO

=over

=item More documentation:
mod_perl2 introduction, some WAF joint (especially Mojolicious)...

=item More performance up

Contribution to Plack core project.
ModPerl::PSGI is experiment of Plac::Handler::Apache2 on the technical side.

=item Writing mod_perl1 version.

=back

=head1 SEE ALSO

L<Plack>, L<Plack::Handler::Apache2>, L<Plack::Util>

Many code base is referred to Plack's stuffs.
But ModPerl::PSGI does not have any Plack dependencies.

ModPerl::PSGI depends B<ONLY> Perl 5.8 core and mod_perl2 core modules.

=head1 AUTHOR

OGATA Tetsuji, E<lt>tetsuji.ogata {at} gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by OGATA Tetsuji

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
