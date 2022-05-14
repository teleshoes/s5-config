#!/usr/bin/perl
use strict;
use warnings;

use POSIX qw(strftime);
use HTML::Entities qw(decode_entities);
use MIME::Base64 qw(decode_base64);
use Digest::MD5 qw(md5_hex);
use Encode qw(decode_utf8 encode_utf8);

sub parseSmsXml($$);
sub parseMmsXml($$);
sub parseSmsMmsXml($$$);
sub parseCallsXml($$);
sub getAtt($$$$);
sub formatSMS($);
sub formatCall($);
sub formatDurationHMS($);
sub createMMSDir($$);
sub cleanBody($);
sub cleanNumber($);
sub formatDateMillis($);
sub getMd5($$$);

my $usage = "Usage:
  $0 --sms XML_FILE SMS_OUT_FILE
    -parse <sms> tags into format:
      <NUMBER>,<DATE_MILLIS>,<DATE_SENT_MILLIS>,<SMS_OR_MMS>,<INC_OR_OUT>,<DATE_FMT>,<TEXT>

  $0 --mms XML_FILE MMS_OUT_DIR
    -parse <mms> tags into individual msg dirs underneath MMS_OUT_DIR
      named:
        <MMS_OUT_DIR>/<DATE_MILLIS>_<PHONE-PHONE-PHONE>_<INC_OR_OUT>_<MD5_OF_CONTENTS>/
      containing:
        each file attachment, named PART_NAME
        a file named 'info' formatted:
          from=<PHONE>
          to=<PHONE>
          to=<PHONE>
          to=<PHONE>
          dir=<INC_OR_OUT>
          date=<DATE_MILLIS>
          date_sent=<DATE_MILLIS>
          subject=<SUBJECT>
          body=<BODY>

  $0 --sms-mms XML_FILE SMS_OUT_FILE MMS_OUT_DIR
    -parse both <sms> and <mms> tags, as in --sms and --mms, at the same time

  $0 --calls XML_FILE CALLS_OUT_FILE
    -parse <call> tags into format:
      <NUMBER>,<DATE_MILLIS>,<INC_OR_OUT_OR_MIS>,<DATE_FMT>,<DURATION_FMT>
";

sub main(@){
  $| = 1;
  if(@_ == 3 and $_[0] =~ /^(--sms)$/){
    my ($xmlSrc, $smsDestFile) = ($_[1], $_[2]);

    die "ERROR: $smsDestFile file already exists\n" if -e $smsDestFile;

    parseSmsXml($xmlSrc, $smsDestFile);
  }elsif(@_ == 3 and $_[0] =~ /^(--mms)$/){
    my ($xmlSrc, $mmsDestDir) = ($_[1], $_[2]);

    die "ERROR: $mmsDestDir is not a dir\n" if not -d $mmsDestDir;

    parseMmsXml($xmlSrc, $mmsDestDir);
  }elsif(@_ == 4 and $_[0] =~ /^(--sms-mms)$/){
    my ($xmlSrc, $smsDestFile, $mmsDestDir) = ($_[1], $_[2], $_[3]);

    die "ERROR: $smsDestFile file already exists\n" if -e $smsDestFile;
    die "ERROR: $mmsDestDir is not a dir\n" if not -d $mmsDestDir;

    parseSmsMmsXml($xmlSrc, $smsDestFile, $mmsDestDir);
  }elsif(@_ == 3 and $_[0] =~ /^(--calls)$/){
    my ($xmlSrc, $callsDestFile) = ($_[1], $_[2]);

    die "ERROR: $callsDestFile already exists\n" if -e $callsDestFile;

    parseCallsXml($xmlSrc, $callsDestFile);
  }else{
    die $usage;
  }
}

sub parseSmsXml($$){
  my ($xmlFile, $smsDestFile) = @_;
  parseSmsMmsXml($xmlFile, $smsDestFile, undef);
}
sub parseMmsXml($$){
  my ($xmlFile, $mmsDestDir) = @_;
  parseSmsMmsXml($xmlFile, undef, $mmsDestDir);
}
sub parseSmsMmsXml($$$){
  my ($xmlFile, $smsDestFile, $mmsDestDir) = @_;
  my $count = 0;
  my $total = 0;

  my $curSMS = undef;
  my $curMMS = undef;

  if(defined $smsDestFile){
    open SMS_OUT_FH, "> $smsDestFile" or die "ERROR: could not write $smsDestFile\n$!\n";
    binmode SMS_OUT_FH, "encoding(UTF-8)";
  }

  open XML_FILE, "< $xmlFile" or die "ERROR: could not read $xmlFile\n$!\n";

  while(my $line = <XML_FILE>){
    chomp $line;
    chop $line if $line =~ /\r$/;

    next if $line =~ /^<\?xml.*\?>$/;
    next if $line =~ /^<!--/;
    next if $line =~ /-->$/;
    next if $line =~ /^\s*$/;
    next if $line =~ /^To view this file in a more readable format.*$/;

    next if $line =~ /^\s*<parts>\s*$/;
    next if $line =~ /^\s*<parts\s*\/\s*>\s*$/;
    next if $line =~ /^\s*<\/parts>\s*$/;

    next if $line =~ /^\s*<addrs>\s*$/;
    next if $line =~ /^\s*<addrs \/>\s*$/;
    next if $line =~ /^\s*<\/addrs>\s*$/;

    next if $line =~ /^\s*<\/smses>\s*$/;

    if($line =~ /^\s*<smses(\s+[^<>]*)>\s*$/){
      $total       = getAtt($line, 1, "count", qr/\d+/);
    }elsif($line =~ /^\s*<sms(\s+[^<>]*)>\s*$/){
      if(defined $smsDestFile){
        my $date     = getAtt($line, 1, "date",      qr/^\d{13}$/);
        my $dateSent = getAtt($line, 1, "date_sent", qr/^(\d{10}|\d{13}|0)$/);
        my $type     = getAtt($line, 1, "type",      qr/^(1|2)$/);
        my $addr     = getAtt($line, 1, "address",   qr/^.*$/);
        my $body     = getAtt($line, 1, "body"   ,   qr/^.*$/);

        $dateSent = "${dateSent}000" if $dateSent =~ /^\d{10}$/;
        $dateSent = $date            if $dateSent =~ /^0*$/;

        my $dir = $type == 1 ? "INC" : "OUT";

        $curSMS = {
          addr     => $addr,
          date     => $date,
          dateSent => $dateSent,
          dir      => $dir,
          body     => $body,
        };
        print SMS_OUT_FH formatSMS($curSMS);
        $curSMS = undef;
      }
      $count++;
      print "$count/$total\n" if $count % 100 == 0 or $count >= $total;
    }elsif($line =~ /^\s*<mms(\s+[^<>]*)>\s*$/){
      if(defined $mmsDestDir){
        my $date     = getAtt($line, 1, "date",      qr/^\d{13}$/);
        my $dateSent = getAtt($line, 1, "date_sent", qr/^(\d{10}|\d{13}|0)$/);
        my $subject  = getAtt($line, 1, "sub",       qr/^.*$/);
        my $mType    = getAtt($line, 1, "m_type",    qr/^.*$/);
        my $addr     = getAtt($line, 0, "address",   qr/^.*$/);

        $dateSent = "${dateSent}000" if $dateSent =~ /^\d{10}$/;
        $dateSent = $date            if $dateSent =~ /^0*$/;

        $subject = "" if $subject eq "null";

        my $dir;
        if($mType == 128){
          $dir = "OUT";
        }elsif($mType == 132){
          $dir = "INC";
        }elsif($mType == 130){
          $dir = "NTF";
        }else{
          die "ERROR: unknown MMS direction type '$mType'\n$line";
        }

        die "ERROR: missing </mms> tag\n" if defined $curMMS;
        $curMMS = {
          subject    => $subject,
          dir        => $dir,
          date       => $date,
          dateSent   => $dateSent,
          mainAddr   => $addr,
          sender     => undef,
          recipients => [],
          parts      => [],
        };
      }
      $count++;
      print "$count/$total\n" if $count % 100 == 0 or $count >= $total;
    }elsif($line =~ /^\s*<\/mms>\s*$/){
      if(defined $mmsDestDir){
        createMMSDir($mmsDestDir, $curMMS);
        $curMMS = undef;
      }
    }elsif($line =~ /^\s*<part\s+([^<>]+?)(?:\s+data="([^"]*)")?\s*\/>$/){
      if(defined $mmsDestDir){
        my ($atts, $data) = ($1, $2);
        my $ct       = getAtt($atts, 1, "ct",        qr/^.+$/);
        my $name     = getAtt($atts, 1, "name",      qr/^.*$/);
        my $cl       = getAtt($atts, 1, "cl",        qr/^.*$/);
        my $text     = getAtt($atts, 1, "text",      qr/^.*$/);

        if($atts =~ /data=['"]/){
          die "ERROR: att 'data' must be last in <part> and use \"s (optimization)\n";
        }
        die "ERROR: <part> outside of <mms>\n" if not defined $curMMS;
        $data = decode_base64($data) if defined $data;

        push @{$$curMMS{parts}}, {
          ct   => $ct,
          name => $name,
          cl   => $cl,
          text => $text,
          data => $data,
        };
      }
    }elsif($line =~ /^\s*<addr(\s+[^<>]*)>\s*$/){
      if(defined $mmsDestDir){
        my $addr     = getAtt($line, 1, "address",   qr/^.*$/);
        my $type     = getAtt($line, 1, "type",      qr/^\d+$/);
        die "ERROR: <addr> outside of <mms>\n" if not defined $curMMS;
        if($type =~ /^(137)$/){
          #from=137
          if(defined $$curMMS{sender}){
            die "ERROR: too many 'from' addresses:\n$line";
          }
          $$curMMS{sender} = $addr;
        }elsif($type =~ /^(151|130|129)$/){
          #to=151, cc=130, bcc=129
          push @{$$curMMS{recipients}}, $addr;
        }else{
          die "ERROR: invalid MMS addr direction type:\n$line";
        }
      }
    }else{
      die "ERROR: malformed line:\n$line";
    }
  }
  close XML_FILE;

  close SMS_OUT_FH;

  die "ERROR: last SMS not written\n" if defined $curSMS;
  die "ERROR: last MMS not written\n" if defined $curMMS;
}

sub parseCallsXML($$){
  my ($xmlFile, $callsDestFile) = @_;
  my $count = 0;
  my $total = 0;

  my $curCall = undef;

  open CALLS_OUT_FH, "> $callsDestFile" or die "ERROR: could not write $callsDestFile\n$!\n";
  binmode CALLS_OUT_FH, "encoding(UTF-8)";

  open XML_FILE, "< $xmlFile" or die "ERROR: could not read $xmlFile\n$!\n";

  while(my $line = <XML_FILE>){
    chomp $line;
    chop $line if $line =~ /\r$/;

    next if $line =~ /^<\?xml.*\?>$/;
    next if $line =~ /^<!--/;
    next if $line =~ /-->$/;
    next if $line =~ /^\s*$/;
    next if $line =~ /^To view this file in a more readable format.*$/;

    next if $line =~ /^\s*<\/calls>\s*$/;

    if($line =~ /^\s*<calls(\s+[^<>]*)>\s*$/){
      $total       = getAtt($line, 1, "count", qr/\d+/);
    }elsif($line =~ /^\s*<call(\s+[^<>]*)>\s*$/){
      my $number   = getAtt($line, 1, "number",    qr/^.*$/);
      my $date     = getAtt($line, 1, "date",      qr/^\d{13}$/);
      my $type     = getAtt($line, 1, "type",      qr/^(1|2|3|5)$/);
      my $duration = getAtt($line, 1, "duration",  qr/^\d+$/);

      my $dir;
      if($type eq 1){
        $dir = "INC";
      }elsif($type eq 2){
        $dir = "OUT";
      }elsif($type eq 3){
        $dir = "MIS";
      }elsif($type eq 5){
        $dir = "REJ";
      }else{
        die "ERROR: invalid call dir type $type\n";
      }

      $count++;
      print "$count/$total\n" if $count % 100 == 0 or $count >= $total;

      $curCall = {
        number   => $number,
        date     => $date,
        dir      => $dir,
        duration => $duration,
      };
      print CALLS_OUT_FH formatCall($curCall);
      $curCall = undef;
    }else{
      die "ERROR: malformed line:\n$line";
    }
  }
  close XML_FILE;

  close CALLS_OUT_FH;

  die "ERROR: last call not written\n" if defined $curCall;
}

sub getAtt($$$$){
  my ($xml, $required, $attName, $valRegex) = @_;
  my $val;
  $val = $1 if not defined $val and $xml =~ /\s+$attName='([^']*)'/;
  $val = $1 if not defined $val and $xml =~ /\s+$attName="([^"]*)"/;

  if($required and not defined $val){
    die "ERROR: could not find required att '$attName' in:\n$xml\n";
  }
  if(defined $val and $val !~ /^$valRegex$/){
    die "ERROR: invalid value '$val' for $attName\n$xml\n";
  }
  return $val;
}

sub formatSMS($){
  my ($sms) = @_;
  my $fmt = '';
  $fmt .= ""  . cleanNumber($$sms{addr});
  $fmt .= "," . $$sms{date};
  $fmt .= "," . $$sms{dateSent};
  $fmt .= "," . "S";
  $fmt .= "," . $$sms{dir};
  $fmt .= "," . formatDateMillis($$sms{date});
  $fmt .= "," . "\"" . cleanBody($$sms{body}) . "\"";
  $fmt .= "\n";
  return $fmt;
}

sub formatCall($){
  my ($call) = @_;
  my $fmt = '';
  $fmt .= ""  . cleanNumber($$call{number});
  $fmt .= "," . $$call{date};
  $fmt .= "," . $$call{dir};
  $fmt .= "," . formatDateMillis($$call{date});
  $fmt .= "," . formatDurationHMS($$call{duration});
  $fmt .= "\n";
  return $fmt;
}

sub formatDurationHMS($){
  my ($durSex) = @_;
  my $isNeg = 0;
  if($durSex < 0){
    $isNeg = 1;
    $durSex = 0-$durSex;
  }
  my $h = int($durSex / 60 / 60);
  my $m = int($durSex / 60) % 60;
  my $s = int($durSex) % 60;
  my $durFmt;
  if($isNeg){
    $durFmt = sprintf "-%01dh %02dm %02ds", $h, $m, $s;
  }else{
    $durFmt = sprintf " %01dh %02dm %02ds", $h, $m, $s;
  }

  return $durFmt;
}

sub createMMSDir($$){
  my ($baseDir, $mms) = @_;
  if(not -d $baseDir){
    die "ERROR: $baseDir is not a dir\n";
  }

  my $body = '';

  my $attFiles = {};

  my $attFileIndex = 0;

  for my $part(@{$$mms{parts}}){
    my $ct = $$part{ct};
    my $fileName = $$part{cl};
    my $text = $$part{text};
    my $data = $$part{data};
    if($ct =~ /smil/){
      next;
    }elsif($ct =~ /^text\/plain$/){
      if($body ne ""){
        print STDERR "WARNING: concatenating multiple text parts for MMS $$mms{date}\n";
      }
      if(not defined $text){
        die "ERROR: missing text for text/plain part for MMS $$mms{date}\n";
      }
      $body .= $text;
    }else{
      if(not defined $fileName or $fileName eq "null" or $fileName =~ /^\s*$/){
        $fileName = $$part{name};
      }
      if(not defined $fileName or $fileName eq "null" or $fileName =~ /^\s*$/){
        $fileName = "";
      }
      die "ERROR: $fileName cannot contain /s\n" if $fileName =~ /\//;

      $attFileIndex++;
      my $prefix = "PART_" . ($$mms{date} + $attFileIndex);
      if($fileName eq ""){
        $fileName = $prefix;
      }else{
        $fileName = "${prefix}_${fileName}";
      }
      if(defined $$attFiles{$fileName}){
        die "ERROR: duplicate filename for MMS $$mms{date}\n";
      }
      $$attFiles{$fileName} = $data;
    }
  }

  my $md5 = getMd5(cleanBody($$mms{subject}), cleanBody($body), $attFiles);

  my $from = cleanNumber($$mms{sender});
  $from = "None" if $from eq "";

  my @tos = map{cleanNumber($_)} @{$$mms{recipients}};

  my $info = '';
  $info .= "from=" . $from . "\n";
  for my $to(@tos){
    $info .= "to=" . $to . "\n";
  }
  $info .= "dir=" . $$mms{dir} . "\n";
  $info .= "date=" . $$mms{date} . "\n";
  $info .= "date_sent=" . $$mms{dateSent} . "\n";
  $info .= "subject=\"" . cleanBody($$mms{subject}) . "\"\n";
  $info .= "body=\"" . cleanBody($body) . "\"\n";
  for my $fileName(sort keys %$attFiles){
    $info .= "att=$fileName\n";
  }
  $info .= "checksum=" . $md5 . "\n";

  my $dirName = '';
  $dirName .= ""  . $$mms{date};
  if($$mms{dir} eq "OUT"){
    $dirName .= "_" . join("-", @tos);
  }else{
    $dirName .= "_" . $from;
  }
  $dirName .= "_" . $$mms{dir};
  $dirName .= "_" . $md5;

  my $msgDir = "$baseDir/$dirName";
  system "mkdir", "-p", $msgDir;

  open INFO_FH, "> $msgDir/info" or die "ERROR: could not write $msgDir/info\n$!\n";
  binmode INFO_FH, "encoding(UTF-8)";
  print INFO_FH $info;
  close INFO_FH;

  for my $fileName(sort keys %$attFiles){
    open ATT_FH, "> $msgDir/$fileName" or die "ERROR: could not write $msgDir/$fileName\n$!\n";
    binmode ATT_FH;
    print ATT_FH $$attFiles{$fileName};
    close ATT_FH;
  }
}

sub cleanBody($){
  my ($body) = @_;

  $body = decode_utf8($body);
  $body = decode_entities($body);
  $body =~ s/"/\\"/g;
  $body =~ s/\r/\\r/g;
  $body =~ s/\n/\\n/g;
  return $body;
}

sub cleanNumber($){
  my ($number) = @_;
  $number = '' if not defined $number;
  $number =~ s/[^+0-9]//g;
  $number =~ s/^\+?1(\d{10})$/$1/;
  return $number;
}

sub formatDateMillis($){
  my ($dateMillis) = @_;
  return strftime("%Y-%m-%d %H:%M:%S", localtime(int($dateMillis/1000.0)));
}

sub getMd5($$$){
  my ($subject, $body, $attFiles) = @_;
  my $msg = '';
  $msg .= $subject if defined $subject;
  $msg .= $body if defined $body;
  for my $fileName(sort keys %$attFiles){
    my $contents = $$attFiles{$fileName};
    $msg .= "\n$fileName\n";
    $msg .= $contents;
  }
  return md5_hex(encode_utf8($msg));
}

&main(@ARGV);
