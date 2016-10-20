#!/usr/bin/perl
use strict;
use warnings;

sub main(@){
  for my $file(`ls *.sms`){
    chomp $file;
    next if -l $file;
    my $contents = `cat $file`;
    open FH, "> $file";
    while($contents =~ /^([0-9+]+),(\d+),(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d),"((?:[^"\n]|""|\n)*)"/mgi){
      my ($num, $dir, $date, $msg) = ($1, $2, $3, $4);
      $msg =~ s/\\/\\\\/g;
      $msg =~ s/""/\\"/g;
      $msg =~ s/\n/\\n/g;
      my $line = "$num,$dir,$date,\"$msg\"\n";
      print FH $line;
    }
    close FH;
  }
}

&main(@ARGV);
