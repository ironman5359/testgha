#!/usr/bin/env ruby

require 'json'
require 'open3'
require 'securerandom'
require 'net/http'
require 'uri'
require 'openssl'
require 'fileutils'

def run_shell(command)
  stdout, stderr, status = Open3.capture3(command)
  unless status.success?
    raise "Command '#{command}' failed with error: #{stderr}"
  end
  stdout.strip
end

# Define necessary functions
def confirm(token, arg1 = 'confirmation')
  branch = ENV['GITHUB_REF'].sub('refs/heads/', '')
  migration = ENV['MIGRATION']
  slack_hook = ENV['SLACK_CONFIRMATION_HOOK_PASSWORD']
  run_url = ENV['RUN_URL']

  message = <<~MSG
    🙋 The migration *#{migration}* in *#{branch}* is awaiting #{arg1} -- when you are ready to proceed, reply in this channel with: `confirm #{token} <optional value here>` or to cancel `confirm #{token} cancel` - do _NOT_ share sensitive values here, refer to the readme and use the get_secret command instead for those.
  MSG

  uri = URI.parse(slack_hook)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Post.new(uri.path, {'Content-Type' => 'application/json'})
  req.body = { text: message }.to_json
  http.request(req)

  # Check for response
  loop do
    sleep 1
    response, status = Open3.capture2("curl --write-out '\\n%{http_code}' --silent 'https://worker-throbbing-tooth-3494.rayatheapp.workers.dev/?secret=#{ENV['CLOUDFLARE_CONFIRMATION_WORKER_PASSWORD']}&key=#{token}'")
    http_status = status.exitstatus
    response.strip!

    if http_status != 200 && http_status != 201
      puts "Error: Confirm command failed with status #{http_status} and response #{response}"
    elsif response == 'cancel'
      puts "[✋] Operation cancelled by user with token #{token}."
      exit 1
    elsif !response.empty?
      puts "[✋] ...response received for token #{token} and stored. Proceeding!"
      ENV['CONFIRM_RESPONSE'] = response
      return
    end
  end
end

def get_secret(secret_name)
  vault_username = ENV['ONE_PW_INPUTS_VAULT_USERNAME']
  stdout = run_shell("op item get --vault #{vault_username} --format json #{secret_name}")
  data = JSON.parse(stdout)

  data['fields'].each do |field|
    puts "::add-mask::#{field['value']}"
    unless field['label'].include?("notesPlain")
      File.write("#{ENV['HOME']}/.notes/#{data['title'].upcase}", field['value'])
    end
  end

  # Update environment variables
  ENV.update(data['fields'].filter { |c| !c['label'].include?("notesPlain") }.map { |c| ["#{data['title'].upcase}_#{c['label'].upcase}", c['value']] }.to_h)
end

def set_secret(title, filename)
  puts "[🔒] Creating 1pw secret called #{title}"

  unless system("which zip > /dev/null")
    run_shell("sudo yum update -y")
    run_shell("sudo yum install -y zip")
  end

  zip_file = "#{filename}.zip"
  `zip #{zip_file} #{filename}`
  run_shell("op document create #{zip_file} --title #{title} --vault #{ENV['ONE_PW_OUTPUTS_VAULT_USERNAME']}")
  File.delete(zip_file)

  puts "[🔒] Done, check #{ENV['ONE_PW_OUTPUTS_VAULT_USERNAME']} in 1pw for an item named #{title}!"
end

def update_config
  configmap_path = "#{ENV['HOME']}/.configmap.env"
  return if File.exist?(configmap_path)

  puts "[⚙️] Downloading environment variables for #{ENV['ENVIRONMENT']}"

  # Fetching and setting configmap/env vars
  configmap_env = run_shell("k get configmap raya-backend -o json")
  configmap_data = JSON.parse(configmap_env)

  File.write(configmap_path, configmap_data['data'].map { |k, v| "#{k}=\"#{v}\"" }.join("\n"))

  # Setting secrets
  secrets_env = run_shell("k get secret raya-backend -o json")
  secrets_data = JSON.parse(secrets_env)

  File.open(configmap_path, 'a') do |file|
    file.puts secrets_data['data'].map { |k, v| "#{k}=\"#{atob(v)}\"" }.join("\n")
  end

  # Additional replacements based on environment
  if ENV['ENVIRONMENT'] == 'icecream'
    %w[backend instagram logs].each do |suffix|
      run_shell("sed -i 's|mongodb://mongo/raya-#{suffix}|mongodb://mongo/raya-#{suffix}?directConnection=true|g' #{configmap_path}")
    end
  elsif ENV['ENVIRONMENT'] == 'production'
    vars = %w[INSTAGRAM_MONGOLAB_URI LOG_MONGOLAB_URI MONGOLAB_URI]
    values = [ENV['MONGO_INSTAGRAM'], ENV['MONGO_LOG'], ENV['MONGO_BACKEND']]
    File.open(configmap_path, 'a') do |file|
      vars.each_with_index { |v, idx| file.puts "#{v}=\"#{values[idx]}\"" }
    end
  end
end

def setup_raya_backend
  puts "[⚙️] Setting up Raya-Backend repo for use"
  run_shell("gem install foreman")

  # Clone the repo and update config
  repo_dir = 'raya-backend'
  system("git clone git@github.com:RayaTheApp/#{repo_dir}.git")
  Dir.chdir(repo_dir) do
    run_shell("git fetch")
    run_shell("npm install")
    update_config
  end
end

def setup_mongo
  return if system("which mongosh > /dev/null")

  puts "[⚙️] Downloading and configuring Mongo for first-time use"
  run_shell("sudo yum install -y libcurl openssl xz-libs wget tar --allowerasing")
  run_shell("wget https://downloads.mongodb.com/compass/mongosh-2.0.2-linux-arm64-openssl3.tgz")
  run_shell("tar -zxvf mongosh-2.0.2-linux-arm64-openssl3.tgz")
  FileUtils.mv(Dir.glob("mongosh-2.0.2-linux-arm64-openssl3/bin/*"), '/usr/bin/')
end

def setup_psql
  return if system("which psql > /dev/null")

  puts "[⚙️] Downloading and configuring Postgres"
  run_shell("sudo yum update -y")
  run_shell("sudo yum install -y postgresql15")
end

def raya_mongo
  setup_mongo
  update_config
  system("mongosh #{ENV['MONGOLAB_URI']}")
end

def raya_mongo_log
  setup_mongo
  update_config
  system("mongosh #{ENV['LOG_MONGOLAB_URI']}")
end

def raya_psql
  setup_psql

  if ENV['ENVIRONMENT'] == 'production'
    system("psql 'postgres://#{ENV['PG_RYA_USERNAME']}:#{ENV['PG_RYA_PASSWORD']}@raya-api.cve8lqv89isc.us-east-1.rds.amazonaws.com:5432/raya_api'")
  else
    update_config
    system("psql #{ENV['MAIN_PQ_DATABASE_URL']}")
  end
end

def raya_psql_log
  setup_psql
  update_config
  system("psql #{ENV['LOG_PQ_DATABASE_URL']}")
end

def raya_psql_relationships
  setup_psql
  update_config
  system("psql #{ENV['RELATIONSHIPS_PQ_DATABASE_URL']}")
end

def raya_psql_swipes
  setup_psql
  update_config
  system("psql #{ENV['MAIN_PQ_SWIPES_WRITER_DATABASE_URL']}")
end

def run(script)
  puts "[💃] We are about to run a node script called #{script}"
  code = system("foreman run --env #{ENV['HOME']}/.configmap.env node --max-old-space-size=4096 #{script}")
  puts "[💃] The script #{script} completed with exit code: #{code}"
end

# Assert requirements
run_shell("../../lib/assert-requirements.rb")

if ENV['ENVIRONMENT'] == 'production'
  puts "[😴] Production migration, send disclaimer to Slack and sleep for 60 seconds."
  run_shell("../../lib/generate-production-run-disclaimer.rb")
  sleep 60
end

# Generate confirmation token
token = SecureRandom.hex(3).downcase

confirm(token, "confirmation before running in environment #{ENV['ENVIRONMENT']} by #{ENV['AUTHOR']}")
