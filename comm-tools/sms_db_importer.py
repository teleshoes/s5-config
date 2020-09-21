#!/usr/bin/python
import argparse
import codecs
import filecmp
import glob
import hashlib
import os.path
import re
import sqlite3
import subprocess
import sys
import time

VERBOSE = False
NO_COMMIT = False
REMOTE_MMS_PARTS_DIR = "/data/user_de/0/com.android.providers.telephony/app_parts"
REMOTE_MMS_PARTS_REGEX = r'/data/user\w*/\d+/com.android.providers.telephony/app_parts'

argHelp = { 'COMMAND':          ( 'import-to-db\n'
                                + '  extract SMS from <SMS_CSV_FILE>\n'
                                + '  and output to <DB_FILE>\n'
                                + '\n'
                                + 'export-from-db\n'
                                + '  extract SMS/MMS from <DB_FILE> and <MMS_PARTS_DIR>\n'
                                + '  and output to <SMS_CSV_FILE> and <MMS_MSG_DIR>\n'
                                )
          , '--sms-csv-file':   ( 'SMS CSV file to import-from/export-to')
          , '--db-file':        ( 'pre-existing mmssms.db file to import-to/export-from')
          , '--mms-parts-dir':  ( 'local copy of app_parts dir to import-to/expot-from\n'
                                + '  ' + REMOTE_MMS_PARTS_DIR + '\n'
                                )
          , '--mms-msg-dir':    ( 'directory of MMS messages to import-from/export-to')
          , '--verbose':        ( 'verbose output, slower')
          , '--no-commit':      ( 'do not actually save changes, no SQL commit')
          , '--limit':          ( 'limit to the most recent <LIMIT> messages')
          }

SMS_DIR_OUT = 'OUT'
SMS_DIR_INC = 'INC'
SMS_DIRS = [SMS_DIR_OUT, SMS_DIR_INC]
MMS_DIR_OUT = 'OUT'
MMS_DIR_INC = 'INC'
MMS_DIR_NTF = 'NTF'
MMS_DIRS = [MMS_DIR_OUT, MMS_DIR_INC, MMS_DIR_NTF]

class UsageFormatter(argparse.HelpFormatter):
  def __init__(self, prog):
    argparse.HelpFormatter.__init__(self, prog)
    self._width = 100
    self._max_help_position = 40
  def _split_lines(self, text, width):
    return text.splitlines()

def main():
  parser = argparse.ArgumentParser(
    description='Import/export messages to/from android MMS/SMS database file.',
    formatter_class=UsageFormatter)
  parser.add_argument('COMMAND',           help=argHelp['COMMAND'])
  parser.add_argument('--db-file',         help=argHelp['--db-file'])
  parser.add_argument('--sms-csv-file',    help=argHelp['--sms-csv-file'])
  parser.add_argument('--mms-parts-dir',   help=argHelp['--mms-parts-dir'], default="./app_parts")
  parser.add_argument('--mms-msg-dir',     help=argHelp['--mms-msg-dir'],   default="./mms_messages")
  parser.add_argument('--verbose', '-v',   help=argHelp['--verbose'],       action='store_true')
  parser.add_argument('--no-commit', '-n', help=argHelp['--no-commit'],     action='store_true')
  parser.add_argument('--limit',           help=argHelp['--limit'],         type=int, default=0)
  args = parser.parse_args()

  global VERBOSE, NO_COMMIT
  VERBOSE = args.verbose
  NO_COMMIT = args.no_commit

  if args.db_file == None:
    parser.print_help()
    print("\n--db-file is required")
    quit(1)

  if args.COMMAND == "export-from-db":
    if args.sms_csv_file == None:
      print("skipping SMS export, no <SMS_CSV_FILE> for writing to")
    else:
      texts = readTextsFromAndroid(args.db_file)
      print("read " + str(len(texts)) + " SMS messages from " + args.db_file)
      f = codecs.open(args.sms_csv_file, 'w', 'utf-8')
      for txt in texts:
        f.write(txt.toCsv() + "\n")
      f.close()

    if not os.path.isdir(args.mms_msg_dir):
      print("skipping MMS export, no <MMS_MSG_DIR> for writing to")
    elif not os.path.isdir(args.mms_parts_dir):
      print("skipping MMS export, no <MMS_PARTS_DIR> to read attachments from")
    else:
      mmsMessages = readMMSFromAndroid(args.db_file, args.mms_parts_dir)
      print("read " + str(len(mmsMessages)) + " MMS messages from " + args.db_file)
      attFileCount = 0
      for msg in mmsMessages:
        dirName = msg.getMsgDirName()
        msgDir = args.mms_msg_dir + "/" + dirName
        if not os.path.isdir(msgDir):
          os.mkdir(msgDir)
        infoFile = codecs.open(msgDir + "/" + "info", 'w', 'utf-8')
        infoFile.write(msg.getInfo())
        infoFile.close()
        for attName in sorted(msg.attFiles.keys()):
          srcFile = msg.attFiles[attName]
          destFile = msgDir + "/" + attName
          if 0 != os.system("cp -ar --reflink '" + srcFile + "' '" + destFile + "'"):
            print("failed to copy " + str(srcFile))
            quit(1)
          attFileCount += 1
      print("copied " + str(attFileCount) + " files from " + args.mms_parts_dir)
  elif args.COMMAND == "import-to-db":
    texts = []
    if args.sms_csv_file == None or not os.path.isfile(args.sms_csv_file):
      print("skipping SMS import, no <SMS_CSV_FILE> for reading from")
    else:
      print("Reading texts from CSV file:")
      starttime = time.time()
      texts = readTextsFromCSV(args.sms_csv_file)
      print("finished in {0} seconds, {1} messages read".format( (time.time()-starttime), len(texts) ))

      print("sorting all {0} texts by date".format(len(texts)))
      texts = sorted(texts, key=lambda text: text.date_millis)

      if args.limit > 0:
        print("saving only the last {0} messages".format( args.limit ))
        texts = texts[ (-args.limit) : ]

    mmsMessages = []
    if not os.path.isdir(args.mms_msg_dir):
      print("skipping MMS import, no <MMS_MSG_DIR> for reading from")
    elif not os.path.isdir(args.mms_parts_dir):
      print("skipping MMS import, no <MMS_PARTS_DIR> to write attachments to")
    else:
      print("reading mms from " + args.mms_msg_dir)
      mmsMessages = readMMSFromMsgDir(args.mms_msg_dir, args.mms_parts_dir)
      attFileCount = 0
      for mms in mmsMessages:
        dirName = mms.getMsgDirName()
        msgDir = args.mms_msg_dir + "/" + dirName
        if not os.path.isdir(msgDir):
          print("ERROR: missing MMS message dir=" + str(msgDir) + "\n" + str(mms))
          quit(1)

        oldChecksum = mms.checksum
        mms.generateChecksum()
        newChecksum = mms.checksum

        if oldChecksum != newChecksum:
          print("ERROR: mismatched checksum for MMS message\n" + str(mms))
          quit(1)

        attFilePrefix = dirName
        for filename in sorted(list(mms.attFiles.keys())):
          srcFile = mms.attFiles[filename]
          # prefix any file that doesnt start with PART_<MILLIS>
          if regexMatch(r'^PART_\d{13}', filename):
            destFile = args.mms_parts_dir + "/" + filename
          else:
            destFile = args.mms_parts_dir + "/" + attFilePrefix + "_" + filename

          if os.path.isfile(destFile):
            if not filecmp.cmp(srcFile, destFile, shallow=False):
              print("ERROR: attFile exists in parts dir and is different\n" + str(mms))
              quit(1)

          if 0 != os.system("cp -ar --reflink '" + srcFile + "' '" + destFile + "'"):
            print("ERROR: failed to copy " + str(srcFile))
            quit(1)
          mms.attFiles[filename] = destFile
          attFileCount += 1

      print("read " + str(len(mmsMessages)) + " MMS messages")
      print("copied " + str(attFileCount) + " files to " + args.mms_parts_dir)

    print("Saving changes into Android DB (mmssms.db), "+str(args.db_file))
    importMessagesToDb(texts, mmsMessages, args.db_file)
  else:
    print("invalid <COMMAND>: " + args.COMMAND)
    print("  (expected one of 'export-from-db' or 'import-to-db')")
    quit(1)

def md5Update(md5, msg):
  if type(msg) == str:
    md5.update(msg.encode("utf-8"))
  else:
    md5.update(msg)

class Text:
  def __init__( self, number, date_millis, date_sent_millis,
              sms_mms_type, direction, date_format, body):
    self.number = number
    self.date_millis = date_millis
    self.date_sent_millis = date_sent_millis
    self.sms_mms_type = sms_mms_type
    self.direction = direction
    self.date_format = date_format
    self.body = body
  def toCsv(self):
    date_sent_millis = self.date_sent_millis
    if date_sent_millis == 0:
      date_sent_millis = self.date_millis
    return (""
      + ""  + cleanNumber(self.number)
      + "," + str(self.date_millis)
      + "," + str(date_sent_millis)
      + "," + self.sms_mms_type
      + "," + self.getDirection()
      + "," + self.date_format
      + "," + "\"" + escapeStr(self.body) + "\""
    )
  def isOutgoing(self):
    return self.isDirection(SMS_DIR_OUT)
  def isIncoming(self):
    return self.isDirection(SMS_DIR_INC)
  def isDirection(self, smsDir):
    self.assertDirectionValid()
    return self.direction == smsDir
  def getDirection(self):
    self.assertDirectionValid()
    return self.direction
  def assertDirectionValid(self):
    if self.direction not in SMS_DIRS:
      print("ERROR: invalid SMS direction=" + str(self.direction))
      quit(1)
  def __str__(self):
    return self.toCsv()

def escapeStr(s):
  return (s
    .replace('&', '&amp;')
    .replace('\\', '&backslash;')
    .replace('\n', '\\n')
    .replace('\r', '\\r')
    .replace('"', '\\"')
    .replace('&backslash;', '\\\\')
    .replace('&amp;', '&')
  )

def unescapeStr(s):
  return (s
    .replace('&', '&amp;')
    .replace('\\\\', '&backslash;')
    .replace('\\n', '\n')
    .replace('\\r', '\r')
    .replace('\\"', '"')
    .replace('&backslash;', '\\')
    .replace('&amp;', '&')
  )

class MMS:
  def __init__(self, mms_parts_dir):
    self.mms_parts_dir = mms_parts_dir
    self.from_number = None
    self.to_numbers = []
    self.date_millis = None
    self.date_sent_millis = None
    self.direction = None
    self.date_format = None
    self.subject = None

    self.parts = []
    self.body = None
    self.attFiles = {}
    self.checksum = None
  def parseParts(self):
    self.body = None
    self.attFiles = {}
    self.checksum = None
    for p in self.parts:
      if 'smil' in p.part_type:
        pass
      elif p.body != None:
        if self.body != None:
          print("WARNING: multiple text parts for mms (concatenating them)\n" + str(self))
          self.body += p.body
        self.body = p.body
      elif p.filepath != None:
        filename = p.filepath
        filename = regexSub('^' + REMOTE_MMS_PARTS_REGEX + '/', '', filename)
        if "/" in filename:
          print("ERROR: filename contains path sep '/'\n" + filename)
          quit(1)
        prefixRegex = re.compile(''
          + r'^\d+_'
          + r'([0-9+]+-)*[0-9+]+_'
          + r'(' + '|'.join(sorted(MMS_DIRS)) + r')_'
          + r'[0-9a-f]{32}_'
          )
        unprefixedFilename = prefixRegex.sub('', filename)
        attName = unprefixedFilename
        localFilepath = self.mms_parts_dir + "/" + filename
        self.attFiles[attName] = localFilepath
      else:
        print("ERROR: invalid MMS part=" + str(p))
        quit(1)
    if self.body == None:
      self.body = ""
    self.checksum = self.generateChecksum()
  def generateChecksum(self):
    md5 = hashlib.md5()
    if self.subject != None:
      md5Update(md5, escapeStr(self.subject))
    if self.body != None:
      md5Update(md5, escapeStr(self.body))
    for attName in sorted(self.attFiles.keys()):
      md5Update(md5, "\n" + attName + "\n")
      filepath = self.attFiles[attName]
      if not os.path.isfile(filepath):
        print("ERROR: missing att file=" + filepath)
        quit(1)
      f = open(filepath, 'rb')
      md5Update(md5, f.read())
      f.close()
    return md5.hexdigest()
  def getMsgDirName(self):
    dirName = ""
    dirName += str(self.date_millis)
    dirName += "_"
    if self.isOutgoing():
      dirName += "-".join(self.to_numbers)
    elif self.isIncoming():
      dirName += str(self.from_number)
    dirName += "_"
    dirName += self.getDirection()
    dirName += "_"
    dirName += str(self.checksum)
    return dirName
  def getInfo(self):
    date_sent_millis = self.date_sent_millis
    if date_sent_millis == 0:
      date_sent_millis = self.date_millis
    info = ""
    info += "from=" + str(self.from_number) + "\n"
    for to_number in self.to_numbers:
      info += "to=" + str(to_number) + "\n"
    info += "dir=" + self.getDirection() + "\n"
    info += "date=" + str(self.date_millis) + "\n"
    info += "date_sent=" + str(date_sent_millis) + "\n"
    info += "subject=\"" + escapeStr(self.subject) + "\"\n"
    info += "body=\"" + escapeStr(self.body) + "\"\n"
    for attName in sorted(self.attFiles.keys()):
      info += "att=" + str(attName) + "\n"
    info += "checksum=" + str(self.checksum) + "\n"
    return info
  def isOutgoing(self):
    return self.isDirection(MMS_DIR_OUT)
  def isIncoming(self):
    return self.isDirection(MMS_DIR_INC) or self.isDirection(MMS_DIR_NTF)
  def isDirection(self, mmsDir):
    self.assertDirectionValid()
    return self.direction == mmsDir
  def getDirection(self):
    self.assertDirectionValid()
    return self.direction
  def assertDirectionValid(self):
    if self.direction not in MMS_DIRS:
      print("ERROR: invalid MMS direction=" + str(self.direction))
      quit(1)
  def __str__(self):
    return self.getInfo()

class MMSPart:
  def __init__(self):
    self.part_type = None
    self.filename = None
    self.filepath = None
    self.body = None

def cleanNumber(number):
  if number == None:
    number = ''
  number = regexSub(r'[^+0-9]', '', number)
  number = regexSub(r'^\+?1(\d{10})$', '\\1', number)
  return number

def readTextsFromCSV(csvFile):
  try:
    csvFile = open(csvFile, 'r')
    csvContents = csvFile.read()
    csvFile.close()
  except IOError:
    print("ERROR: could not read csv file=" + str(csvFile))
    quit(1)

  texts = []
  rowRegex = re.compile(''
    + r'([0-9+]+),'
    + r'(\d+),'
    + r'(\d+),'
    + r'(S|M),'
    + r'(' + '|'.join(sorted(SMS_DIRS)) + r'),'
    + r'([^,]*),'
    + r'\"(.*)\"'
    )
  for row in csvContents.splitlines():
    m = rowRegex.match(row)
    if not m or len(m.groups()) != 7:
      print("ERROR: invalid SMS CSV line=" + row)
      quit(1)
    number           = m.group(1)
    date_millis      = m.group(2)
    date_sent_millis = m.group(3)
    sms_mms_type     = m.group(4)
    direction        = m.group(5)
    date_format      = m.group(6)
    body             = unescapeStr(m.group(7))

    if direction not in SMS_DIRS:
      print("ERROR: invalid SMS direction=" + direction)
      quit(1)

    texts.append(Text( number
                     , date_millis
                     , date_sent_millis
                     , sms_mms_type
                     , direction
                     , date_format
                     , body
                     ))
  return texts

def readTextsFromAndroid(db_file):
  conn = sqlite3.connect(db_file)
  c = conn.cursor()
  i=0
  texts = []
  query = c.execute(
    'SELECT address, date, date_sent, type, body \
     FROM sms \
     ORDER BY _id ASC;')
  for row in query:
    number = row[0]
    date_millis = int(row[1])
    date_sent_millis = int(row[2])
    sms_mms_type = "S"
    dir_type = row[3]

    error = False
    direction = None
    if dir_type == 2: #MESSAGE_TYPE_SENT
      direction = SMS_DIR_OUT
    elif dir_type == 1: #MESSAGE_TYPE_INBOX
      direction = SMS_DIR_INC
    elif dir_type == 3: #MESSAGE_TYPE_DRAFT
      #do not backup drafts
      pass
    elif dir_type == 5: #MESSAGE_TYPE_FAILED (failed to send)
      #no message sent
      pass
    elif dir_type == 6: #MESSAGE_TYPE_QUEUED (sending later)
      #no message sent yet
      pass
    elif dir_type == 4: #MESSAGE_TYPE_OUTBOX (sending now)
      print("WARNING: SKIPPING SMS FOR OUTBOX DIR TYPE=" + str(dir_type) + "\n" + str(row))
      error = False
    elif dir_type == 0: #MESSAGE_TYPE_ALL
      error = True
    else:
      error = True

    if error:
      print("ERROR: INVALID SMS DIRECTION TYPE=" + str(dir_type) + "\n" + str(row))
      quit(1)
    elif direction != None:
      body = row[4]
      date_format = time.strftime("%Y-%m-%d %H:%M:%S",
        time.localtime(date_millis/1000))

      txt = Text(number, date_millis, date_sent_millis,
        sms_mms_type, direction, date_format, body)
      texts.append(txt)
      if VERBOSE:
        print(str(txt))
  return texts

def readMMSFromMsgDir(mmsMsgDir, mms_parts_dir):
  msgDirs = glob.glob(mmsMsgDir + "/*")

  mmsMessages = []
  keyValRegex = re.compile(r'^\s*(\w+)\s*=\s*"?(.*?)"?\s*$')
  for msgDir in sorted(msgDirs):
    msgInfo = msgDir + "/" + "info"
    if not os.path.isfile(msgInfo):
      print("ERROR: missing \"info\" file for msg dir=" + msgDir)
      quit(1)
    f = open(msgInfo)
    infoLines = f.read().splitlines()
    mms = MMS(mms_parts_dir)
    for infoLine in infoLines:
      m = keyValRegex.match(infoLine)
      if not m or len(m.groups()) != 2:
        print("ERROR: malformed mms info line=" + infoLine)
        quit(1)
      key = m.group(1)
      val = m.group(2)
      if key == "from":
        mms.from_number = val
      elif key == "to":
        mms.to_numbers.append(val)
      elif key == "date":
        mms.date_millis = int(val)
        mms.date_format = time.strftime("%Y-%m-%d %H:%M:%S",
          time.localtime(mms.date_millis/1000))
      elif key == "date_sent":
        mms.date_sent_millis = int(val)
      elif key == "dir":
        if val not in MMS_DIRS:
          print("ERROR: invalid MMS direction=" + str(val))
          quit(1)
        mms.direction = val
      elif key == "subject":
        mms.subject = unescapeStr(val)
      elif key == "body":
        mms.body = unescapeStr(val)
      elif key == "att":
        attName = val
        filepath = msgDir + "/" + val
        mms.attFiles[attName] = filepath
      elif key == "checksum":
        mms.checksum = val
    mmsMessages.append(mms)
  return mmsMessages

def readMMSFromAndroid(db_file, mms_parts_dir):
  conn = sqlite3.connect(db_file)
  c = conn.cursor()
  i=0
  texts = []
  query = c.execute(
    'SELECT _id, date, date_sent, m_type, sub \
     FROM pdu \
     ORDER BY _id ASC;')
  msgs = {}
  for row in query:
    msg_id = row[0]
    date_millis = int(row[1]) * 1000
    date_sent_millis = int(row[2]) * 1000
    dir_type_mms = row[3]
    subject = row[4]

    if subject == None:
      subject = ""

    if dir_type_mms == 128:
      direction = MMS_DIR_OUT
    elif dir_type_mms == 132:
      direction = MMS_DIR_INC
    elif dir_type_mms == 130:
      direction = MMS_DIR_NTF
    else:
      print("ERROR: INVALID MMS DIRECTION TYPE=" + str(dir_type_mms) + "\n" + str(row))
      quit(1)

    date_format = time.strftime("%Y-%m-%d %H:%M:%S",
      time.localtime(date_millis/1000))

    msg = MMS(mms_parts_dir)
    msg.date_millis = date_millis
    msg.date_sent_millis = date_sent_millis
    msg.direction = direction
    msg.date_format = date_format
    msg.subject = subject

    msgs[msg_id] = msg

  query = c.execute(
    'SELECT mid, ct, name, _data, text \
     FROM part \
     ORDER BY _id ASC;')

  for row in query:
    msg_id = row[0]
    part_type = row[1]
    filename = row[2]
    filepath = row[3]
    body = row[4]

    #skip malformed SMIL, happens for NTF messages
    if msg_id not in msgs and part_type == "application/smil":
      continue

    if msg_id not in msgs:
      print("\n\n\n===\nWARNING: INVALID MESSAGE ID FOR MMS PART=" + str(row))
      continue
    msg = msgs[msg_id]

    part = MMSPart()
    part.part_type = part_type
    part.filename = filename
    part.filepath = filepath
    part.body = body
    msg.parts.append(part)

  for msg in msgs.values():
    msg.parseParts()

  query = c.execute(
    'SELECT msg_id, address, type \
     FROM addr \
     ORDER BY msg_id ASC;')

  for row in query:
    msg_id = row[0]
    number = row[1]
    dir_type_addr = row[2]

    is_sender_addr = False
    is_recipient_addr = False
    if dir_type_addr == 137:
      is_sender_addr = True
    elif dir_type_addr == 151:
      is_recipient_addr = True
    else:
      print("WARNING: SKIPPING MSG, INVALID MMS ADDR DIR=" + str(dir_type_addr) + "\n" + str(row))
      next

    if msg_id not in msgs:
      print("ERROR: INVALID MESSAGE ID FOR ADDRESS\n" + str(row))
      quit(1)
    msg = msgs[msg_id]

    if is_sender_addr:
      if msg.from_number != None:
        print("ERROR: too many sender addresses for address row\n" + str(row))
        quit(1)
      msg.from_number = cleanNumber(number)
    elif is_recipient_addr:
      msg.to_numbers.append(cleanNumber(number))

  return msgs.values()

def getDbTableNames(db_file):
  cur = sqlite3.connect(db_file).cursor()
  names = cur.execute("SELECT name FROM sqlite_master WHERE type='table'; ")
  names = [name[0] for name in names]
  cur.close()
  return names

def insertRow(cursor, tableName, colVals):
  (colNames, values) = zip(*colVals.items())
  valuePlaceHolders = list(map(lambda val: "?", values))
  cursor.execute( " INSERT INTO " + tableName
                + " (" + ", ".join(colNames) + ")"
                + " VALUES (" + ", ".join(valuePlaceHolders) + ")"
                , values)

def importMessagesToDb(texts, mmsMessages, db_file):
  conn = sqlite3.connect(db_file)
  c = conn.cursor()

  for txt in texts:
    txt.number = cleanNumber(txt.number)
  for mms in mmsMessages:
    mms.from_number = cleanNumber(mms.from_number)
    toNumbers = []
    for toNumber in mms.to_numbers:
      toNumbers.append(cleanNumber(toNumber))
    mms.to_numbers = toNumbers

  allNumbers = set()
  for txt in texts:
    allNumbers.add(txt.number)
  for mms in mmsMessages:
    allNumbers.add(mms.from_number)
    for toNumber in mms.to_numbers:
      allNumbers.add(toNumber)

  contactIdByNumber = {}
  canonicalAddressByNumber = {}
  query = c.execute("SELECT _id, address FROM canonical_addresses;")
  for row in query:
    contactId = row[0]
    addr = row[1]
    number = cleanNumber(addr)
    contactIdByNumber[number] = contactId
    canonicalAddressByNumber[number] = addr

  for number in allNumbers:
    #add canonical addr and thread
    if not number in contactIdByNumber:
      insertRow(c, "canonical_addresses", {"address": number})
      contactId = c.lastrowid
      insertRow(c, "threads", {"recipient_ids": contactId})
      contactIdByNumber[number] = contactId
      canonicalAddressByNumber[number] = number

      if VERBOSE:
        print("added new contact addr: " + str(number) + " => " + str(contactId))

  for mms in mmsMessages:
    numbers = []
    if mms.isOutgoing():
      for toNumber in mms.to_numbers:
        numbers.append(toNumber)
    elif mms.isIncoming():
      numbers.append(mms.from_number)

    for number in numbers:
      contactId = contactIdByNumber[number]

      c.execute(""
        + " UPDATE threads SET"
        + "   message_count = message_count + 1,"
        + "   snippet=?,"
        + "   'date'=?"
        + " WHERE recipient_ids=?"
        , [ mms.body
          , mms.date_millis
          , contactId])
      c.execute(""
        + " SELECT _id"
        + " FROM threads"
        + " WHERE recipient_ids=?"
        , [contactId])
      threadId = c.fetchone()[0]

      if mms.isDirection(MMS_DIR_OUT):
        m_type = 128
        retr_st = None
      elif mms.isDirection(MMS_DIR_INC):
        m_type = 132
        retr_st = 128
      elif mms.isDirection(MMS_DIR_NTF):
        m_type = 130
        retr_st = None

      insertRow(c, "pdu", { "thread_id":   threadId
                          , "date":        int(mms.date_millis / 1000)
                          , "date_sent":   int(mms.date_sent_millis / 1000)
                          , "msg_box":     1
                          , "read":        1
                          , "m_id":        None
                          , "sub":         mms.subject
                          , "sub_cs":      None
                          , "ct_t":        "application/vnd.wap.multipart.related"
                          , "ct_l":        None
                          , "exp":         None
                          , "m_cls":       None
                          , "m_type":      m_type
                          , "v":           18
                          , "m_size":      None
                          , "pri":         None
                          , "rr":          None
                          , "rpt_a":       None
                          , "resp_st":     None
                          , "st":          None
                          , "tr_id":       None
                          , "retr_st":     retr_st
                          , "retr_txt":    None
                          , "retr_txt_cs": None
                          , "read_status": None
                          , "ct_cls":      None
                          , "resp_txt":    None
                          , "d_tm":        None
                          , "d_rpt":       None
                          , "locked":      0
                          , "sub_id":      1
                          , "phone_id":    -1
                          , "seen":        1
                          , "creator":     None
                          , "text_only":   1 if len(mms.attFiles) == 0 else 0
                          })
      msgId = c.lastrowid

      insertRow(c, "addr", { "msg_id":     msgId
                           , "contact_id": None  #always null
                           , "address":    canonicalAddressByNumber[mms.from_number]
                           , "type":       137   #sender address
                           , "charset":    3     #? - sometimes the character set is 106
                           })
      for toNumber in mms.to_numbers:
        insertRow(c, "addr", { "msg_id":     msgId
                             , "contact_id": None  #always null
                             , "address":    canonicalAddressByNumber[toNumber]
                             , "type":       151   #recipient address
                             , "charset":    3     #? - sometimes the character set is 106
                             })

      nextContentId = 0
      for attName in sorted(mms.attFiles.keys()):
        localFilepath = mms.attFiles[attName]
        filename = regexSub(r'^.*/', '', localFilepath)
        remoteFilepath = REMOTE_MMS_PARTS_DIR + "/" + filename

        contentType = guessContentType(attName, localFilepath)

        insertRow(c, "part", { "mid":   msgId
                             , "seq":   0
                             , "ct":    contentType
                             , "name":  filename
                             , "chset": None
                             , "cd":    None
                             , "fn":    None
                             , "cid":   "<" + str(nextContentId) + ">"
                             , "cl":    filename
                             , "ctt_s": None
                             , "ctt_t": None
                             , "_data": remoteFilepath
                             , "text":  None
                             })
        nextContentId += 1

      insertRow(c, "part", { "mid":   msgId
                           , "seq":   0
                           , "ct":    "text/plain"
                           , "name":  "body.txt"
                           , "chset": 3     #? - sometimes the character set is 106
                           , "cd":    None
                           , "fn":    None
                           , "cid":   "<" + str(nextContentId) + ">"
                           , "cl":    filename
                           , "ctt_s": None
                           , "ctt_t": None
                           , "_data": None
                           , "text":  mms.body
                           })
      nextContentId += 1

  startTime = time.time()
  count=0
  contactsSeen = set()
  elapsedS = 0
  smsPerSec = 0
  statusMsg = ""

  for txt in texts:
    contactId = contactIdByNumber[txt.number]

    c.execute(""
      + " UPDATE threads SET"
      + "   message_count = message_count + 1,"
      + "   snippet=?,"
      + "   'date'=?"
      + " WHERE recipient_ids=?"
      , [ txt.body
        , txt.date_millis
        , contactId])
    c.execute(""
      + " SELECT _id"
      + " FROM threads"
      + " WHERE recipient_ids=?"
      , [contactId])
    threadId = c.fetchone()[0]

    if VERBOSE:
      print("thread_id = "+ str(threadId))
      c.execute(""
        + " SELECT *"
        + " FROM threads"
        + " WHERE _id=?"
        , [contactId])
      print("updated thread: " + str(c.fetchone()))
      print("adding entry to message db: " + str(txt))

    if txt.isDirection(SMS_DIR_OUT):
      dir_type = 2
    elif txt.isDirection(SMS_DIR_INC):
      dir_type = 1

    #add message to sms table
    insertRow(c, "sms", { "address":     canonicalAddressByNumber[txt.number]
                        , "date":        txt.date_millis
                        , "date_sent":   txt.date_sent_millis
                        , "body":        txt.body
                        , "thread_id":   threadId
                        , "type":        dir_type
                        , "read":        1
                        , "seen":        1
                        })

    count += 1
    contactsSeen.add(contactId)
    elapsedS = time.time() - startTime
    smsPerSec = int(count / elapsedS + 0.5)
    statusMsg = " {0:6d} SMS for {1:4d} contacts in {2:6.2f}s @ {3:5d} SMS/s".format(
                  count, len(contactsSeen), elapsedS, smsPerSec)

    if count % 100 == 0:
      sys.stdout.write("\r" + statusMsg)
      sys.stdout.flush()

  print("\n\nfinished:\n" + statusMsg)

  print("\n\nupdating dates on threads:\n")
  c.execute(""
    + " update threads set date="
    + "   ifnull ("
    + "     nullif ("
    + "       (select max("
    + "         ifnull(mms_date_millis, 0),"
    + "         ifnull(sms_date_millis, 0))"
    + "       from ( select max(pdu.date)*1000 as mms_date_millis"
    + "              from pdu where pdu.thread_id = threads._id and pdu.date"
    + "            ),"
    + "            ( select max(sms.date) as sms_date_millis"
    + "              from sms where sms.thread_id = threads._id"
    + "            )"
    + "       ), 0)"
    + "     , threads.date)"
    )

  if VERBOSE:
    print("\n\nthreads: ")
    for row in c.execute('SELECT * FROM threads'):
      print(row)

  if not NO_COMMIT:
    conn.commit()
    print("changes saved to " + db_file)

  c.close()
  conn.close()

def guessContentType(filename, filepath):
  if regexMatch(r'^.*\.(jpg|jpeg)$', filename, re.IGNORECASE):
    contentType = "image/jpeg"
  elif regexMatch(r'^.*\.(png)$', filename, re.IGNORECASE):
    contentType = "image/png"
  elif regexMatch(r'^.*\.(gif)$', filename, re.IGNORECASE):
    contentType = "image/gif"
  elif regexMatch(r'^.*\.(wav)$', filename, re.IGNORECASE):
    contentType = "audio/wav"
  elif regexMatch(r'^.*\.(flac)$', filename, re.IGNORECASE):
    contentType = "audio/flac"
  elif regexMatch(r'^.*\.(ogg)$', filename, re.IGNORECASE):
    contentType = "audio/ogg"
  elif regexMatch(r'^.*\.(mp3|mp2|m2a|mpga)$', filename, re.IGNORECASE):
    contentType = "audio/mpeg"
  elif regexMatch(r'^.*\.(mp4)$', filename, re.IGNORECASE):
    contentType = "video/mp4"
  elif regexMatch(r'^.*\.(mkv)$', filename, re.IGNORECASE):
    contentType = "video/x-matroska"
  elif regexMatch(r'^.*\.(webm)$', filename, re.IGNORECASE):
    contentType = "video/webm"
  elif regexMatch(r'^.*\.(mpg|mpeg|m1v|m2v)$', filename, re.IGNORECASE):
    contentType = "video/mpeg"
  elif regexMatch(r'^.*\.(avi)$', filename, re.IGNORECASE):
    contentType = "video/avi"
  elif regexMatch(r'^.*\.(3gp)$', filename, re.IGNORECASE):
    contentType = "video/3gpp"
  else:
    mimeType = result = subprocess.check_output([ "file"
                                                , "--mime"
                                                , "--brief"
                                                , filepath
                                                ])
    mimeType = regexSub(r';.*', '', mimeType)
    if regexMatch(r'^[a-z0-9]+/[a-z0-9\-.]+$', mimeType):
      return mimeType
    else:
      print("ERROR: unknown file type=" + filepath)
      quit(1)

  return contentType

def regexMatch(pattern, string, flags=0):
  if type(string) != str:
    string = string.decode("utf-8")
  return re.match(pattern, string, flags)

def regexSub(pattern, repl, string, count=0, flags=0):
  if type(string) != str:
    string = string.decode("utf-8")
  return re.sub(pattern, repl, string, count, flags)

if __name__ == '__main__':
  main()
