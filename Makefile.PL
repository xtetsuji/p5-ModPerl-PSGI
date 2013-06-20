# -*- perl -*-

use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME           => 'ModPerl::PSGI',
    VERSION_FROM   => 'lib/ModPerl/PSGI.pm',
    ABSTRACT_FROM  => 'lib/ModPerl/PSGI.pm',
    AUTHOR         => 'OGATA Tetsuji <tetsuji.ogata at cpan.org>',
    PREREQ_PM      => {
        'Apache2::Const'       => 0,
        'Apache2::RequestRec'  => 0,
        'Apache2::RequestUtil' => 0,
        'Apache2::SubRequest'  => 0,
    },
    PMLIBDIRS      => ["lib"],
    META_MERGE     => {
        resources => {
            license    => 'http://dev.perl.org/licenses/',
            bugtracker => 'https://github.com/xtetsuji/p5-ModPerl-PSGI/issues',
            repository => 'git://github.com/xtetsuji/p5-ModPerl-PSGI.git',
        },
    },
    LISENSE        => "perl",
    PL_FILES       => {},
    EXE_FILES      => [],
    dist           => {
        SUFFIX => 'gz',
        COMPRESS => 'gzip -9f',
    },
);

# TODO: Better ModPerl::MM than EUMM?
