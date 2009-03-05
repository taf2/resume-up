#!/usr/bin/env ruby
#
# Simple HTTP Upload Server.
# 
#  Author: Todd A. Fisher <todd.fisher@gmail.com>
# 
# Implementation of the following proposal:
# see: http://code.google.com/p/gears/wiki/ResumableHttpRequestsProposal
#
# == Synopsis
#
# uploader: Provides an HTTP Server for recieving chunked file uploads
#
# == Usage
#
# hello [OPTION] ... DIR
#
# -h, --help:
#    show help
# 
# --port x, -p x:
#    bind to port x
#
# --authorizer [class], -a [class]:
#    load a specific class to handle authorizing the initiate requests
#
# --auth-url [url], -c [url]:
#    using the standard authrorizer, what host to use for checking authentication
#
# --no-auth-redirect [url], -x [url]:
#    in the event authentication was denied, what url to redirect to, default is 403
#
# --daemonize, -d:
#    daemonize the server process
#
# --pid, -P:
#    path to drop pid file
#
# --kill, -k:
#    kill a running daemonized process
#
# --log, -l:
#    path to log file
#
=begin

Summary of HTTP flow

Client sends initial handshake:

POST /upload HTTP/1.1
Host: example.com
Content-Length: 0
Content-Range: bytes */100


Server assigns ETag:

HTTP/1.1 308 Resume Incomplete
ETag: "vEpr6barcD"
Content-Length: 0

Client initiates upload:

POST /upload HTTP/1.1
Host: example.com
If-Match: "vEpr6barcD"
Content-Length: 100
Content-Range: 0-99/100

[bytes 0-99]

Client polls the server to determine which bytes it has received:

POST /upload HTTP/1.1
Host: example.com
If-Match: "vEpr6barcD"
Content-Length: 0
Content-Range: bytes */100

Server responds with the current byte range:

HTTP/1.1 308 Resume Incomplete
ETag: "vEpr6barcD"
Content-Length: 0
Range: 0-42

Client resumes where the server left off:

POST /upload HTTP/1.1
Host: example.com
If-Match: "vEpr6barcD"
Content-Length: 57
Content-Range: 43-99/100

[bytes 43-99]

This time the server receives everything and sends its response:

HTTP/1.1 200 OK
ETag: "vEpr6barcD"
Content-Length: 10

[response]
=end
#begin
#  require 'minigems'
#rescue => e
  require 'rubygems'
#end

ROOT_PATH    = File.dirname(File.expand_path(__FILE__)).freeze
VIEW_PATH    = File.join(ROOT_PATH,'views').freeze
PUBLIC_FILES = File.join(ROOT_PATH,'public').freeze
DATA_FILES   = File.join(ROOT_PATH,'data-files').freeze

# Upload Controller
class Uploads
  def initialize(layout,authorizer=nil)
    @layout = layout
    @authorizer = authorizer
  end

  def call(env)
    request_path = env['REQUEST_PATH']
    #puts request_path.inspect
    if request_path.match(/^\/upload.*/)
      request = Rack::Request.new(env)
      return upload(request,env)
    elsif request_path.match(/^\/.*/)
      real_path = File.join(PUBLIC_FILES,request_path)
      #puts "real_path: #{real_path.inspect}"
      if request_path != '/' and File.exist?(real_path)
        ext = File.extname(real_path)
        content_type = case ext
        when '.css' then 'text/css'
        when '.js' then 'application/x-javascript'
        when '.html' then 'text/html'
        when '.png' then 'image/png'
        when '.jpg' then 'image/jpeg'
        when '.gif' then 'image/gif'
        else
          'application/octet-stream'
        end
        return [200,{'Content-Type' => content_type}, File.read(real_path) ]
      else
        request = Rack::Request.new(env)
        return index(request,env)
      end
    end
  rescue => e
    error(500, e)
  end

  def index(request,env)
    if @authorizer
      return @authorizer.redirect unless @authorizer.authorized?(env["HTTP_COOKIE"])
    end
    if request.head?
      return [200,{'Content-Type' => 'text/html','Server' => 'thin'}, '']
    else
      return [200,{'Content-Type' => 'text/html'}, render_with_layout('index') ]
    end
  rescue => e
    error(500, e)
  end

  def upload(request,env)
    key = env["HTTP_IF_MATCH"]
    key = key.gsub('"','') if key
    file_path = upload_path(key)

    #puts "got key: #{key}"

    #puts "check file: #{file_path}"
    if file_path and File.exist?(file_path)
      #puts "received upload for #{key}"
      #puts "#{key} - content range header: #{env['HTTP_CONTENT_RANGE'].inspect}"
      if request.content_length.to_i > 0 and env["HTTP_CONTENT_RANGE"]
        return upload_part(key, file_path, request, env) # received the bytes and store
      else
        return upload_status(key, file_path, env) # report how many bytes are still pending
      end
    elsif key.nil?
      return upload_initiate(request) # create a new key
    else
      # HTTP_IF_MATCH  was sent but did not match any known file upload... respond with 404
      return [404,{'Content-Type' => 'text/plain'}, "File not found" ]
    end
  rescue => e
    error(500,e)
  end

protected
  #
  # return the upload path for the given request key
  #
  def upload_path(key)
    return nil if key.nil?
    File.join(DATA_FILES, key)
  end

  #
  # take a file name and strip of non-ascii characters
  # and whitespace.
  #
  def normalize(str)
    str.gsub(/[^\w]/,'-').squeeze('-')
  end

  #
  # generate a unique key given a filename
  #
  def unique_key(filename)
    key = Digest::SHA1.hexdigest("#{filename}-#{UUID.timestamp_create}")[0..8] # first 8
    if filename
      ext = File.extname(filename)
      if ext
        key = "#{normalize(filename)}-#{key}#{ext}"
      else
        # use a regex to grab it maybe?
        sext = filename.gsub(/.*\./,'')
        if sext
          key = "#{normalize(filename)}-#{key}.#{sext}"
        else
          key = "#{normalize(filename)}-#{key}"
        end
      end
    end
    key
  end
  # POST /upload HTTP/1.1
  # Host: example.com
  # Content-Length: 0
  # Content-Range: bytes */100
  #
  #
  # Server assigns ETag:
  #
  # HTTP/1.1 308 Resume Incomplete
  # ETag: "vEpr6barcD"
  # Range: 0-0
  # Content-Length: 0
  #
  def upload_initiate(request)
    if @authorizer
      return @authorizer.redirect unless @authorizer.authorized?(request.env["HTTP_COOKIE"])
    end
    key = unique_key(request.params['filename'])
    log "received upload initiate for #{key}"
    #puts "initiate request for #{key} from #{request.params['filename']}"
    File.open( upload_path(key), "w")
    [308, {'ETag' => key, 'Range' => '0-0'},'']
  end

  # log messages
  def log(msg)
    STDERR.puts msg
  end

  # Client initiates upload:
  #
  # POST /upload HTTP/1.1
  # Host: example.com
  # If-Match: "vEpr6barcD"
  # Content-Length: 100
  # Content-Range: 0-99/100
  #
  # [bytes 0-99]
  #
  def upload_part(key, file_path, request, env)
    #log "received upload part for #{key}"
    File.open( file_path, "a") { |f| f.write( request.body.read ) }
    length = File.size(file_path)
    final_length = env["HTTP_CONTENT_RANGE"].gsub(/.*\//,'').to_i
    if length == final_length
      if @filter
        return @filter.apply(file_path, request.env["HTTP_COOKIE"])
      else
        return [200, {'ETag' => key}, %({"uploaded":"#{file_path}"})]
      end
    else
      return [308, {'ETag' => key, 'Range' => "0-#{length}" },'']
    end
  end

  # Client polls the server to determine which bytes it has received:
  #
  # POST /upload HTTP/1.1
  # Host: example.com
  # If-Match: "vEpr6barcD"
  # Content-Length: 0
  # Content-Range: bytes */100
  #
  # Server responds with the current byte range:
  #
  # HTTP/1.1 308 Resume Incomplete
  # ETag: "vEpr6barcD"
  # Content-Length: 0
  # Range: 0-42
  #
  def upload_status(key, file_path, env)
    log "received upload status for #{key}"
    length = File.size(file_path)
    [308, {'ETag' => key, 'Range' => "0-#{length}" },'']
  end

  def error(status,e)
    STDERR.puts e.message
    STDERR.puts e.backtrace.join("\n")
    erubis = Erubis::Eruby.new(File.read(File.join(VIEW_PATH,'500.html.erb')))
    [status,{'Content-Type' => 'text/html'}, erubis.result({:error => e})]
  end

  #
  # given the name of a file in VIEW_PATH, render it within the layout defined
  # Places the contents of the rendered view in the content_body of the layout
  #
  def render_with_layout(view_file_name,variables={})
    # read the file everytime for development ease
    erubis = Erubis::Eruby.new(File.read(File.join(VIEW_PATH,"#{view_file_name}.html.erb")))
    @layout.render({:content_body => erubis.result(variables) })
  end
end

class Layout
  def initialize(layout_path)
    @layout = File.read(layout_path)
  end

  def render(variables)
    erubis = Erubis::Eruby.new(@layout)
    erubis.result(variables)
  end
end

require 'getoptlong'
begin
  require 'rdoc/usage'
rescue LoadError => e
  STDERR.puts "--help, -h requires rdoc"
end

class App
  def self.load_app_deps
    load_gems ['erubis', 'thin', 'uuidtools']
  end
  
  def self.load_gems(gems)
    # initialize the gems
    gems.each do|g|
      begin
        gem g # add the gem to the load path
        require g # require the gem source files
      rescue Gem::LoadError => e
        STDERR.puts "Missing required gem:\n\t#{g}\n"
        STDERR.puts "The following are required:\n"
        gems.each do|ge|
          STDERR.puts "\t#{ge}"
        end
        exit(1)
      end
    end
  end
  def initialize

    @opts = GetoptLong.new(
      [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
      [ '--port', '-p', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--filter', '-f', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--filter-url', '-u', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--authorizer', '-a', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--auth-url', '-c', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--no-auth-redirect', '-x', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--daemonize', '-d', GetoptLong::NO_ARGUMENT ],
      [ '--pid', '-P', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--log', '-l', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--kill', '-k', GetoptLong::NO_ARGUMENT ]
    )
    @port      = 3000
    @daemonize = false
    @authorizer = nil
    @filter = nil
  end

  def execute
    @load_authorizer = false
    @load_filter = false
    @pid_file = nil
    @log_file = nil

    auth_url = "http://localhost:3000/check"
    auth_redirect = nil
    filter_url = nil

    @opts.each do |opt, arg|
      case opt
      when '--help'
        if defined?(RDoc)
          RDoc::usage
        else
          STDERR.puts "missing ruby rdoc"
        end
        exit(0)
      when '--filter'
        load arg
        @load_filter = true
      when '--filter-url'
        filter_url = arg
      when '--authorizer'
        load arg
        @load_authorizer = true
      when '--auth-url'
        auth_url = arg
      when '--no-auth-redirect'
        auth_redirect = arg
      when '--daemonize'
        @daemonize = true
      when '--pid'
        @pid_file = arg
        if !@pid_file.match(/^\//)
          STDERR.puts "pid file path must be absolute"
          exit(1)
        end
      when '--log'
        @log_file = arg
        if !File.exist?(File.dirname(@log_file))
          STDERR.puts "error missing log file folder!"
          exit(1)
        end
      when '--port'
        @port = arg.to_i
      when '--kill'
        if File.exist?("#{ROOT_PATH}/uploader.pid")
          Process.kill("TERM",File.read("#{ROOT_PATH}/uploader.pid").to_i)
        elsif File.exist?(@pid_file)
          Process.kill("TERM",File.read(@pid_file).to_i)
        else
          STDERR.puts("No pid file found at #{ROOT_PATH}/uploader.pid")
        end
        exit(0)
      end
    end

    @pid_file = "#{ROOT_PATH}/uploader.pid" if @pid_file.nil? and @daemonize

    @authorizer = Access::Authorizer.new(auth_url, auth_redirect) if @load_authorizer
    @filter     = Filter::Hook.new(filter_url) if @load_filter

    run_server
  end

  def run_server

    App.load_gems(Access::Authorizer.dependencies) if defined?(Access) and defined?(Access::Authorizer)

    layout = Layout.new(File.join(VIEW_PATH,'layout.default.html.erb'))
    uploader = Rack::URLMap.new('/'  => Uploads.new(layout,@authorizer), '/upload' => Uploads.new(layout,@authorizer))

    log "Loading server on port: #{@port}"

    server = Thin::Server.new('0.0.0.0', @port, uploader)
    log "Logging to: #{@log_file.inspect}"
    server.log_file = @log_file
    server.pid_file = @pid_file
    if @daemonize
      server.daemonize
    end
    server.start
  end

  # log messages
  def log(msg)
    STDERR.puts msg
  end
end

if $0 == __FILE__
  App.load_app_deps
  app = App.new
  app.execute
end
