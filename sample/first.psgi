# -*- perl -*-

my $app = sub {
    my $env = shift;
    my $path_info = $env->{PATH_INFO} || '';
    my $args = $env->{QUERY_STRING} || '';
    my $body = <<END_BODY;
Hello! PSGI! from $env->{REMOTE_ADDR}.

This host is $env->{HTTP_HOST}.

Path is $path_info.

Query is $args.
END_BODY

    return [ 200,
      [ 'Content-Type' => 'text/plain; charset=UTF-8',
        'X-Name' => 'tetsuji' ],
      [ $body ]
  ];
};
