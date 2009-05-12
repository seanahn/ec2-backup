require 'rubygems'
require 'ftools'
require 'fileutils'
require 'socket'
require 'facets'
require 'facets/ziputils'
require 'aws/s3'
include AWS::S3

STARTED = Time.now

def load_properties(properties_filename)
  properties = {}
  File.open(properties_filename, 'r') do |properties_file|
    properties_file.read.each_line do |line|
      line.strip!
      if (line[0] != ?# and line[0] != ?=)
        i = line.index('=')
        if (i)
          properties[line[0..i - 1].strip] = line[i + 1..-1].strip
        else
          properties[line] = ''
        end
      end
    end      
  end
  properties
end

def log(message)
  puts (Time.now - STARTED).to_s + ": " + message
end

def connect_to_s3()
  puts "Connecting to Amazon S3: #{AMAZON_ACCESS_KEY_ID}/#{AMAZON_SECRET_ACCESS_KEY}..."
  Base.establish_connection!(
    :access_key_id     => AMAZON_ACCESS_KEY_ID,
    :secret_access_key => AMAZON_SECRET_ACCESS_KEY
  )
end

def choose_backup()
  # if no backup is found, then exit
  puts "Backup bucket: " + BUCKET
  begin
    Bucket.find(BUCKET)
  rescue ResponseError => error
    puts "No back-ups found for this node: " + BUCKET + "."
    Process.exit
  end

  # read and sort on the key
  backup_keys = []
  Bucket.find(BUCKET).objects.each do |bucket|
    backup_keys |= [bucket.key]
  end
  backup_keys.sort! { |x, y| y <=> x }
  backup_keys.each_with_index { |key, i|
    puts "#{i+1}. #{key}"
  }
  puts "0. Cancel"

  print "Enter your choice:"
  version = gets.to_i

  Process.exit unless version > 0 && version <= backup_keys.length

  backup_keys[version-1]
end

def load_backup(backup_key)
  #prepare the staging area
  puts "Cleaning up #{STAGING_DIR} ..."
  system("rm -rf #{STAGING_DIR}")
  FileUtils::mkdir STAGING_DIR unless File.exist?(STAGING_DIR)
  FileUtils::mkdir "#{STAGING_DIR}/database" unless File.exist? "#{STAGING_DIR}/database"

  puts "Downloading backup: #{backup_key}..."
  open(ZIP, 'wb') do |file|
    S3Object.stream(backup_key, BUCKET) do |chunk|
      file.write chunk
    end
  end

  puts "Unzipping #{ZIP}..."
  pwd = Dir.pwd
  begin
    Dir.chdir STAGING_DIR
    ZipUtils::unzip ZIP_NAME
  ensure
    Dir.chdir pwd
  end
end

def build_zip()
  log "Cleaning up #{STAGING_DIR} ..."
  system("rm -rf #{STAGING_DIR}")
  FileUtils::mkdir_p "#{STAGING_DIR}/database" unless File.exist? "#{STAGING_DIR}/database"

  log "Dumping mysql data..."
  system("#{MYSQL_DUMP_CMD} > #{STAGING_DIR}/database/mysql.sql")
  Dir.multiglob(FILES, :recursive=>true).each do |path|
    dest_dir = STAGING_DIR + (File.dirname(path).match(/^\//) ? "" : "/") + File.dirname(path)
    log "Copying #{path} to #{dest_dir}..."
    FileUtils::mkdir_p dest_dir unless File.exist? dest_dir
    FileUtils.cp_r path, dest_dir
  end

  log "Zipping #{STAGING_DIR} to #{ZIP}..."
  pwd = Dir.pwd
  begin
    Dir.chdir STAGING_DIR
    ZipUtils::zip ".", ZIP_NAME
  ensure
    Dir.chdir pwd
  end
end

def ensure_bucket()
  puts "Backup bucket: " + BUCKET
  begin
    Bucket.find(BUCKET).objects.each do |backup|
      puts "Found backup: " + backup.key
    end
  rescue ResponseError => error
    Bucket.create BUCKET
    puts "Created a new Bucket: " + BUCKET + "."
  end
end

def store_backup()
  # send the backup
  time = Time.now
  backup_key = time.strftime "BACKUP-%Y-%m-%d %H:%M:%S"
  log "Sending over new backup file: " + backup_key + "..."
  S3Object.store(backup_key, open(ZIP), BUCKET)
  log "Successfully sent over the backup."

  # re-read and sort on the key
  backup_keys = []
  Bucket.find(BUCKET).objects.each do |backup|
    backup_keys |= [backup.key]
  end
  backup_keys.sort!

  # remove old revisions except the last 2
  while backup_keys.length > NUM_BACKUPS do
    key_to_delete = backup_keys.shift
    S3Object.delete(key_to_delete, BUCKET) if S3Object.exists? key_to_delete, BUCKET
    log "Deleted old backup: " + key_to_delete + "."
  end
end

SETTINGS = load_properties "settings.properties"
ZIP_NAME = SETTINGS["ZIP_NAME"]
AMAZON_ACCESS_KEY_ID = SETTINGS["AMAZON_ACCESS_KEY_ID"]
AMAZON_SECRET_ACCESS_KEY = SETTINGS["AMAZON_SECRET_ACCESS_KEY"]
MYSQL_RESTORE_CMD = SETTINGS["MYSQL_RESTORE_CMD"]
MYSQL_DUMP_CMD = SETTINGS["MYSQL_DUMP_CMD"]
BUCKET = (SETTINGS["HOST"] != nil ? SETTINGS["HOST"] : Socket.gethostname) + '-backups'
NUM_BACKUPS = SETTINGS["NUM_BACKUPS"].to_i
FILES = SETTINGS["FILES"].split(",").each do |path|
  path.strip!
end
