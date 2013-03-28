package ModPerl::PSGI;

use strict;
use warnings;

use Apache2::Const -compile => qw(:common :http);
use Apache2::RequestRec  ();
use Apache2::RequestUtil (); # for is_initial_req
use Apache2::SubRequest  (); # for internal_redirect

our $VERSION = '0.01';

sub handler {
    my $r = shift;
}

1;

__END__

=pod

=encoding utf-8

=head1 NAME

ModPerl::PSGI - PSGI adaptor for mod_perl2

=head1 SYNOPSIS

 # e.g. in Location or VirtualHost directive
 <Location /path/to/foo>
   ModPerlPSGIApp /real/path/to/foo/app.psgi
 </Location>

=head1 DESCRIPTION

=head1 SEE ALSO

=head1 AUTHOR

OGATA Tetsuji, E<lt>ogata {at} gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by OGATA Tetsuji

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
