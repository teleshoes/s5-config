#!/usr/bin/perl
use strict;
use warnings;

use POSIX qw(strftime);
use HTML::Entities qw(decode_entities);
use MIME::Base64 qw(decode_base64);
use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8);

sub parseXML($$$);
sub getAtt($$$$);
sub formatSMS($);
sub createMMSDir($$);
sub cleanBody($);
sub cleanNumber($);
sub formatDateMillis($);
sub getMd5($$$);

my $usage = "Usage:
  $0 --sms XML_FILE SMS_OUT_FILE MMS_OUT_DIR
    -parse <sms> tags into format:
      <NUMBER>,<DATE_MILLIS>,<DATE_SENT_MILLIS>,<SMS_OR_MMS>,<INC_OR_OUT>,<DATE_FMT>,<TEXT>

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
";

sub main(@){
  $| = 1;
  if(@_ == 4 and $_[0] =~ /^(--sms)$/){
    my ($xmlSrc, $smsDestFile, $mmsDestDir) = ($_[1], $_[2], $_[3]);
    parseXML($xmlSrc, $smsDestFile, $mmsDestDir);
  }else{
    die $usage;
  }
}

sub parseXML($$$){
  my ($xmlFile, $destSMSFile, $destMMSDir) = @_;
  my $count = 0;
  my $total = 0;

  my $curSMS = undef;
  my $curMMS = undef;

  open SMS_OUT_FH, "> $destSMSFile" or die "ERROR: could not write $destSMSFile\n$!\n";
  binmode SMS_OUT_FH, "encoding(UTF-8)";

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
      my $date     = getAtt($line, 1, "date",      qr/^\d+$/);
      my $dateSent = getAtt($line, 1, "date_sent", qr/^\d+$/);
      my $type     = getAtt($line, 1, "type",      qr/^(1|2)$/);
      my $addr     = getAtt($line, 1, "address",   qr/^.*$/);
      my $body     = getAtt($line, 1, "body"   ,   qr/^.*$/);

      $dateSent = $date if $dateSent =~ /^0*$/;

      my $dir = $type == 1 ? "INC" : "OUT";
      $count++;
      print "$count/$total\n" if $count % 100 == 0 or $count == $total;

      $curSMS = {
        addr     => $addr,
        date     => $date,
        dateSent => $dateSent,
        dir      => $dir,
        body     => $body,
      };
      print SMS_OUT_FH formatSMS($curSMS);
      $curSMS = undef;
    }elsif($line =~ /^\s*<mms(\s+[^<>]*)>\s*$/){
      my $date     = getAtt($line, 1, "date",      qr/^\d+$/);
      my $dateSent = getAtt($line, 1, "date_sent", qr/^\d+$/);
      my $subject  = getAtt($line, 1, "sub",       qr/^.*$/);
      my $mType    = getAtt($line, 1, "m_type",    qr/^.*$/);
      my $addr     = getAtt($line, 0, "address",   qr/^.*$/);

      $dateSent = $date if $dateSent =~ /^0*$/;

      $count++;
      print "$count/$total\n" if $count % 100 == 0 or $count == $total;

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
    }elsif($line =~ /^\s*<\/mms>\s*$/){
      createMMSDir($destMMSDir, $curMMS);
      $curMMS = undef;
    }elsif($line =~ /^\s*<part\s+([^<>]+?)(?:\s+data="([^"])*")?\s*\/>$/){
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
    }elsif($line =~ /^\s*<addr(\s+[^<>]*)>\s*$/){
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
    }else{
      die "ERROR: malformed line:\n$line";
    }
  }
  close XML_FILE;

  close SMS_OUT_FH;

  die "ERROR: last SMS not written\n" if defined $curSMS;
  die "ERROR: last MMS not written\n" if defined $curMMS;
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

sub createMMSDir($$){
  my ($baseDir, $mms) = @_;
  if(not -d $baseDir){
    die "ERROR: $baseDir is not a dir\n";
  }

  my $body = '';

  my $attFiles = {};

  my $attFileIndex = 1;

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
        die "ERROR: missing filename for MMS $$mms{date}\n";
      }
      my $prefix = "PART_" . ($$mms{date} + $attFileIndex) . "_";
      $attFileIndex++;
      $fileName = "${prefix}$fileName";
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
  $body =~ s/^['"]//;
  $body =~ s/['"]$//;

  $body = decode_entities($body);
  $body =~ s/"/\\"/g;
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
