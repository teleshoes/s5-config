#!/usr/bin/perl
use strict;
use warnings;
use Digest::MD5;

sub parseMMSDir($);
sub getMMSKey($);
sub getAttFileInfo($$);
sub md5($);
sub run(@);

sub main(@){
  my ($srcDir, $destDir) = @_;
  die "Usage: $0 SRC_DIR DEST_DIR\n" if not -d $srcDir or not -d $destDir;

  my @srcMsgDirs = glob "$srcDir/*/";
  my @destMsgDirs = glob "$destDir/*/";

  my %srcInfoByKey;
  for my $srcMsgDir(@srcMsgDirs){
    my $mmsInfo = parseMMSDir($srcMsgDir);
    my $key = getMMSKey($mmsInfo);
    if(defined $srcInfoByKey{$key}){
      die "ERROR: duplicate src mms key $$mmsInfo{date}\n";
    }else{
      $srcInfoByKey{$key} = $mmsInfo;
    }
  }

  my %destInfoByKey;
  for my $destMsgDir(@destMsgDirs){
    my $mmsInfo = parseMMSDir($destMsgDir);
    my $key = getMMSKey($mmsInfo);
    if(defined $destInfoByKey{$key}){
      #print STDERR "WARNING: duplicate dest mms key $$mmsInfo{date}\n";
    }else{
      $destInfoByKey{$key} = $mmsInfo;
    }
  }

  for my $srcKey(sort keys %srcInfoByKey){
    if(not defined $destInfoByKey{$srcKey}){
      my $srcMsgDir = ${$srcInfoByKey{$srcKey}}{msgDir};
      run "echo", "cp", "-ar", "$srcMsgDir/", "$destDir/";
    }
  }
}

sub parseMMSDir($){
  my ($msgDir) = @_;
  my $infoFile = "$msgDir/info";
  die "ERROR: missing info $infoFile\n" if not -f $infoFile;
  open FH, "< $infoFile" or die "ERROR: could not read $infoFile\n$!\n";
  my $info = {
    msgDir   => $msgDir,
    from     => undef,
    to       => [],
    dir      => undef,
    date     => undef,
    dateSent => undef,
    subject  => undef,
    body     => undef,
    att      => [],
    checksum => undef,
  };
  while(my $line = <FH>){
    if($line =~ /^from=(\d+|None|)$/){
      $$info{from} = $1;
    }elsif($line =~ /^to=(\d+|)$/){
      push @{$$info{to}}, $1;
    }elsif($line =~ /^dir=(INC|OUT|NTF)$/){
      $$info{dir} = $1;
    }elsif($line =~ /^date=(\d+)$/){
      $$info{date} = $1;
    }elsif($line =~ /^date_sent=(\d+)$/){
      $$info{dateSent} = $1;
    }elsif($line =~ /^subject="(.*)"$/){
      $$info{subject} = $1;
    }elsif($line =~ /^body="(.*)"$/){
      $$info{body} = $1;
    }elsif($line =~ /^att=(.+)$/){
      my $attFileName = $1;
      push @{$$info{att}}, getAttFileInfo($msgDir, $attFileName);
    }elsif($line =~ /^checksum=([0-9a-f]{32})$/){
      $$info{checksum} = $1;
    }else{
      die "ERROR: malformed line in $infoFile\n$line";
    }
  }
  return $info;
}

sub getMMSKey($){
  my ($mmsInfo) = @_;
  my $key = '';
  my $from = $$mmsInfo{from};
  $from = "None" if $from eq "";
  $key .= $from . "\n";
  $key .= join("-", @{$$mmsInfo{to}}) . "\n";
  $key .= $$mmsInfo{dir} . "\n";
  $key .= $$mmsInfo{date} . "\n";
  $key .= $$mmsInfo{dateSent} . "\n";
  $key .= $$mmsInfo{subject} . "\n";
  $key .= $$mmsInfo{body} . "\n";
  for my $att(@{$$mmsInfo{att}}){
#    $key .= $$att{unprefixedFileName} . "\n";
    $key .= $$att{md5} . "\n";
  }
  return $key;
}

sub getAttFileInfo($$){
  my ($msgDir, $attFileName) = @_;
  my $file = "$msgDir/$attFileName";
  if(not -f $file){
    die "ERROR: missing att file $file\n";
  }
  my @stat = stat $file;
  my $unprefixedFileName = $attFileName;
  if($unprefixedFileName =~ /^PART_\d+$/){
    $unprefixedFileName = "";
  }else{
    $unprefixedFileName =~ s/^PART_\d+_//;
  }

  my $md5 = md5($file);

  return {
    file               => $file,
    attFileName        => $attFileName,
    unprefixedFileName => $unprefixedFileName,
    mtime              => $stat[9],
    size               => $stat[7],
    md5                => $md5,
  };
}

sub md5($){
  my ($file) = @_;

  open my $fh, "< $file" or die "ERROR: cannot read $file\n$!\n";
  binmode $fh;
  my $md5 = Digest::MD5->new->addfile($fh)->hexdigest();
  close $fh;

  return $md5;
}

sub run(@){
  print "@_\n";
  system @_;
}

&main(@ARGV);
