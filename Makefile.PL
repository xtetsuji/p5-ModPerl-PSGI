# -*- perl -*-

use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME           => 'Apache2::HideFileExtension',
    VERSION_FROM   => 'lib/Apache2/HideFileExtension.pm',
    ABSTRACT_FROM  => 'lib/Apache2/HideFileExtension.pm',
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
            bugtracker => 'https://github.com/xtetsuji/p5-Apache2-HideFileExtension/issues',
            repository => 'git://github.com/xtetsuji/p5-Apache2-HideFileExtension.git',
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
