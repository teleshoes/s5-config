#!/usr/bin/perl
use strict;
use warnings;
use Digest::MD5;
use File::Basename qw(basename);
use File::Type;

my $BACKUP_DIR = "$ENV{HOME}/Code/s5/backup";
my $MMS_REPO_DIR = "$BACKUP_DIR/backup-mms/repo";

my $EXEC = basename $0;

my $USAGE = "Usage:
  $EXEC -h|--help
    show this message

  $EXEC [OPTS] MMS_SRC_DIR
    -parse MMS messages in MMS_DIR and $MMS_REPO_DIR
    -identify duplicates using fuzzy matching:
      -from:     treat from=\"\" as equal to from=\"None\", and then match exactly
      -to:       must match exactly, in order
      -dir:      must match exactly
      -date:     must match exactly
      -dateSent: must match exactly
      -subject:  must match exactly
      -body:     must match exactly
      -atts:     file content MD5 sums must match exactly, in order,
                 but filenames and filetypes are ignored by default
    -copy any new messages into $MMS_REPO_DIR

  OPTS
    -n|-s|--simulate|--no-act|--dry-run
      print the copy commands instead of just running them

    --dest-dir=MMS_DEST_DIR
      use MMS_DEST_DIR instead of $MMS_REPO_DIR

    --att=name
      same as: --att-filename=fuzzy   --att-filetype=ignored --att-md5=ignored
    --att=type
      same as: --att-filename=ignored --att-filetype=exact   --att-md5=ignored
    --att=md5
      same as: --att-filename=ignored --att-filetype=ignored --att-md5=exact
      (these are the defaults)

    --att-filename=MATCH_RULE
      control how att filenames are used to match
      MATCH_RULE
        exact:    must match exactly
        fuzzy:    must match, but prefixes are removed and case is ignored
        ignored:  ignored (this is the default)

    --att-filetype=MATCH_RULE
      control how att filetypes are used to match
      filetypes are determined by the actual file contents, with File::Type perl module
      (also determines whether filetypes are calculated at all, for a small speedup/slowdown)
      MATCH_RULE
        exact:    must match exactly
        ignored:  ignored (this is the default)

    --att-md5=MATCH_RULE
      control how att file content MD5 sums are used to match
      (also determines whether MD5s are calculated at all, for a large speedup/slowdown)
      MATCH_RULE
        exact:    must match exactly (this is the default)
        ignored:  ignored
";

sub parseMMSDir($$$);
sub getMMSKey($@);
sub getAttFileInfo($$$$);
sub filetype($);
sub md5($);
sub run(@);

my $MATCH_RULE_EXACT = "exact";
my $MATCH_RULE_FUZZY = "fuzzy";
my $MATCH_RULE_IGNORED = "ignored";

sub main(@){
  my $simulate = 0;
  my $attFileName = "ignored";
  my $attFileType = "ignored";
  my $attMD5 = "exact";

  my $srcDir;
  my $destDir = $MMS_REPO_DIR;
  while(@_ > 0){
    my $arg = shift @_;
    if($arg =~ /^(-h|--help)$/){
      print $USAGE;
      exit 0;
    }elsif($arg =~ /^-n|-s|--simulate|--no-act|--dry-run$/){
      $simulate = 1;
    }elsif($arg =~ /^--att=name$/){
      $attFileName = $MATCH_RULE_FUZZY;
      $attFileType = $MATCH_RULE_IGNORED;
      $attMD5 =      $MATCH_RULE_IGNORED;
    }elsif($arg =~ /^--att=type$/){
      $attFileName = $MATCH_RULE_IGNORED;
      $attFileType = $MATCH_RULE_EXACT;
      $attMD5 =      $MATCH_RULE_IGNORED;
    }elsif($arg =~ /^--att=md5$/){
      $attFileName = $MATCH_RULE_IGNORED;
      $attFileType = $MATCH_RULE_IGNORED;
      $attMD5 =      $MATCH_RULE_EXACT;
    }elsif($arg =~ /^--att-filename=($MATCH_RULE_EXACT|$MATCH_RULE_FUZZY|$MATCH_RULE_IGNORED)$/){
      $attFileName = $1;
    }elsif($arg =~ /^--att-filetype=($MATCH_RULE_EXACT|$MATCH_RULE_IGNORED)$/){
      $attFileType = $1;
    }elsif($arg =~ /^--att-md5=($MATCH_RULE_EXACT|$MATCH_RULE_IGNORED)$/){
      $attMD5 = $1;
    }elsif($arg =~ /^--dest-dir=(.+)$/){
      $destDir = $1;
      die "ERROR: $destDir is not a directory\n" if not -d $destDir;
    }elsif(-d $arg){
      die "ERROR: more than one MMS_SRC_DIR given\n" if defined $srcDir;
      $srcDir = $arg;
    }else{
      die "$USAGE\nERROR: unknown arg $arg\n";
    }
  }

  die "$USAGE\nERROR: missing MMS_SRC_DIR\n" if not defined $srcDir;

  my $includeFiletype = $attFileType eq $MATCH_RULE_IGNORED ? 0 : 1;
  my $includeMd5 = $attMD5 eq $MATCH_RULE_IGNORED ? 0 : 1;

  my @mmsKeyFields;
  push @mmsKeyFields, "date";
  push @mmsKeyFields, "from";
  push @mmsKeyFields, "to";
  push @mmsKeyFields, "dir";
  push @mmsKeyFields, "dateSent";
  push @mmsKeyFields, "subject";
  push @mmsKeyFields, "body";

  push @mmsKeyFields, "attFileName"           if $attFileName eq $MATCH_RULE_EXACT;
  push @mmsKeyFields, "attUnprefixedFilename" if $attFileName eq $MATCH_RULE_FUZZY;

  push @mmsKeyFields, "attFileType"           if $attFileType eq $MATCH_RULE_EXACT;

  push @mmsKeyFields, "attMD5"                if $attMD5 eq $MATCH_RULE_EXACT;

  my @srcMsgDirs = glob "$srcDir/*/";
  my @destMsgDirs = glob "$destDir/*/";

  my $warningMsg = "";

  my %srcInfoByKey;
  for my $srcMsgDir(@srcMsgDirs){
    my $mmsInfo = parseMMSDir($srcMsgDir, $includeFiletype, $includeMd5);

    my $key = getMMSKey($mmsInfo, @mmsKeyFields);
    if(defined $srcInfoByKey{$key}){
      my $msg = "WARNING: duplicate src mms fuzzy-key (only the first one will be added)\n"
        . "  $srcInfoByKey{$key}{msgDir}\n"
        . "  $srcMsgDir\n"
        . "\n"
      ;
      $warningMsg .= $msg;
      print STDERR $msg;
    }

    $srcInfoByKey{$key} = $mmsInfo;
  }

  my %destInfoByKey;
  my $latestDestDate = 0;
  for my $destMsgDir(@destMsgDirs){
    my $mmsInfo = parseMMSDir($destMsgDir, $includeFiletype, $includeMd5);
    my $key = getMMSKey($mmsInfo, @mmsKeyFields);
    if(defined $destInfoByKey{$key}){
      #no need to warn, existing duplicates are fine
      next;
    }

    $destInfoByKey{$key} = $mmsInfo;
    $latestDestDate = $$mmsInfo{date} if $$mmsInfo{date} > $latestDestDate;
  }

  my @oldMMSDirs;
  my $oldCount = 0;
  my $newCount = 0;
  my $skippedCount = 0;
  for my $srcKey(sort keys %srcInfoByKey){
    if(not defined $destInfoByKey{$srcKey}){
      my $srcMMSInfo = $srcInfoByKey{$srcKey};
      my $srcMsgDir = $$srcMMSInfo{msgDir};
      if($simulate){
        print "#cp -ar $srcMsgDir/ $destDir/\n";
      }else{
        run "cp", "-ar", "$srcMsgDir/", "$destDir/";
      }

      if($$srcMMSInfo{date} < $latestDestDate){
        $oldCount++;
        push @oldMMSDirs, $srcMsgDir;
      }else{
        $newCount++;
      }
    }else{
      $skippedCount++;
    }
  }

  print "\n======\n";

  if(@oldMMSDirs > 0){
    print "\n";
    print "MMS messages that are not skipped, but are older than the latest message on dest:\n";
    print join '', map {"  $_\n"} @oldMMSDirs;
  }

  if(length $warningMsg > 0){
    print "\n$warningMsg";
  }

  print "\n";
  print "$skippedCount MMS messages skipped\n";
  print "$newCount MMS messages newer than the latest message on dest\n";
  print "$oldCount MMS messages older than the latest message on dest\n";
}

sub parseMMSDir($$$){
  my ($msgDir, $includeFiletype, $includeMd5) = @_;
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
      push @{$$info{att}}, getAttFileInfo($msgDir, $attFileName, $includeFiletype, $includeMd5);
    }elsif($line =~ /^checksum=([0-9a-f]{32})$/){
      $$info{checksum} = $1;
    }else{
      die "ERROR: malformed line in $infoFile\n$line";
    }
  }
  return $info;
}

sub getMMSKey($@){
  my ($mmsInfo, @mmsKeyFields) = @_;
  my $key = '';
  my $from = $$mmsInfo{from};
  $from = "" if $from =~ /^None$/i;

  my %okFields = map {$_ => 1} @mmsKeyFields;

  $key .= $$mmsInfo{date} . "\n"               if defined $okFields{date};
  $key .= $from . "\n"                         if defined $okFields{from};
  $key .= join("-", @{$$mmsInfo{to}}) . "\n"   if defined $okFields{to};
  $key .= $$mmsInfo{dir} . "\n"                if defined $okFields{dir};
  $key .= $$mmsInfo{dateSent} . "\n"           if defined $okFields{dateSent};
  $key .= $$mmsInfo{subject} . "\n"            if defined $okFields{subject};
  $key .= $$mmsInfo{body} . "\n"               if defined $okFields{body};

  my @atts = @{$$mmsInfo{att}};
  for my $att(@atts){
    $key .= $$att{unprefixedFileName} . "\n"   if defined $okFields{attUnprefixedFilename};
    $key .= $$att{attFileName} . "\n"          if defined $okFields{attFileName};
    $key .= $$att{attFileType} . "\n"          if defined $okFields{attFileType};
    $key .= $$att{size} . "\n"                 if defined $okFields{attSize};
    $key .= $$att{md5} . "\n"                  if defined $okFields{attMD5};
  }
  return $key;
}

sub getAttFileInfo($$$$){
  my ($msgDir, $attFileName, $includeFiletype, $includeMd5) = @_;
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

  my $attFileType = $includeFiletype ? filetype($file) : "";

  my $md5 = $includeMd5 ? md5($file) : "";

  return {
    file               => $file,
    attFileName        => $attFileName,
    attFileType        => $attFileType,
    unprefixedFileName => $unprefixedFileName,
    mtime              => $stat[9],
    size               => $stat[7],
    md5                => $md5,
  };
}

sub filetype($){
  my ($file) = @_;
  my $mimetype = File::Type->new->mime_type($file);
  return $mimetype;
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
