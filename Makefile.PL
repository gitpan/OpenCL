use ExtUtils::MakeMaker;

WriteMakefile(
    dist	=> {
	            PREOP	=> 'pod2text OpenCL.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
	            COMPRESS	=> 'gzip -9v',
	            SUFFIX	=> '.gz',
	           },
    PM_PREREQ => {
       common::sense => 0,
    },
    NAME => "OpenCL",
    VERSION_FROM => "OpenCL.pm",
    LIBS => ["-lOpenCL"],
);

