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
# --daemonize, -d:
#    daemonize the server process
# --kill, -k:
#    kill a running daemonized process
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

ROOT_PATH=File.dirname(File.expand_path(__FILE__))
VIEW_PATH=File.join(ROOT_PATH,'views')
PUBLIC_FILES=File.join(ROOT_PATH,'public')
DATA_FILES=File.join(ROOT_PATH,'data-files')

# Upload Controller
class Uploads
  def initialize(layout)
    @layout = layout
  end

  def call(env)
    request_path = env['REQUEST_PATH']
    if request_path.match(/^\/upload.*/)
      request = Rack::Request.new(env)
      upload(request,env)
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
        [200,{'Content-Type' => content_type}, File.read(real_path) ]
      else
        request = Rack::Request.new(env)
        index(request,env)
      end
    end
  rescue => e
    error(500, e)
  end

  def index(request,env)
    if request.head?
      return [200,{'Content-Type' => 'text/html','Server' => 'thin'}, '']
    else
      return [200,{'Content-Type' => 'text/html','Server' => 'thin'}, render_with_layout('index') ]
    end
  rescue => e
    error(500, e)
  end

  def upload(request,env)
    key = env["HTTP_IF_MATCH"]
    key = key.gsub('"','') if key
    file_path = upload_path(key)

    #puts "check file: #{file_path}"
    if file_path and File.exist?(file_path)
      #puts "recieved upload for #{key}"
      #puts "#{key} - content range header: #{env['HTTP_CONTENT_RANGE'].inspect}"
      if request.content_length.to_i > 0 and env["HTTP_CONTENT_RANGE"]
        return upload_part(key, file_path, request, env) # recieve the bytes and store
      else
        return upload_status(key, file_path, env) # report how many bytes are still pending
      end
    else
      return upload_initiate(request) # create a new key
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
  # generate a unique key given a filename
  #
  def unique_key(filename)
    key = Digest::SHA1.hexdigest("#{filename}-#{UUID.timestamp_create}")[0..8] # first 8
    if filename
      ext = File.extname(filename)
      if ext
        key = "#{filename.gsub(ext,'')}-#{key}#{ext}"
      else
        key = "#{filename}-#{key}"
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
  # Content-Length: 0
  #
  def upload_initiate(request)
    key = unique_key(request.params['filename'])
    File.open( upload_path(key), "w")
    [308, {'ETag' => key},'']
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
    File.open( file_path, "a") { |f| f.write( request.body.read ) }
    length = File.size(file_path)
    final_length = env["HTTP_CONTENT_RANGE"].gsub(/.*\//,'').to_i
    if length == final_length
      #puts "Completed"
      return [200, {'ETag' => key}, "uploaded: #{file_path}"]
    else
      #puts "Incomplete with 0-#{length} < #{final_length}"
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

class CookieSession
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
  STDERR.puts "--help, -h require rdoc"
end

class App
  def self.load_dependencies
    # initialize the gems
    gems = ['erubis', 'thin', 'uuidtools']
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
      [ '--daemonize', '-d', GetoptLong::NO_ARGUMENT ],
      [ '--kill', '-k', GetoptLong::NO_ARGUMENT ]
    )
    @port = 3000
    @daemonize = false
  end

  def execute
    @opts.each do |opt, arg|
      case opt
      when '--help'
        if defined?(RDoc)
          RDoc::usage
        else
          STDERR.puts "missing ruby rdoc"
        end
        exit(0)
      when '--daemonize'
        @daemonize = true
      when '--port'
        @port = arg.to_i
      when '--kill'
        if File.exist?("#{ROOT_PATH}/uploader.pid")
          Process.kill("TERM",File.read("#{ROOT_PATH}/uploader.pid").to_i)
        else
          STDERR.puts("No pid file found at #{ROOT_PATH}/uploader.pid")
        end
        exit(0)
      end
    end
    run_server
  end

  def run_server
    if @daemonize
      puts "Daemonize"
      gem 'daemons'
      require 'daemons'
      self.class.class_eval { include Daemonize }
      daemonize
      # drop the pid file
      File.open("#{ROOT_PATH}/uploader.pid", "w"){|f| f.write(Process.pid)}
      # listen for exit to cleanup the pid
      at_exit { File.unlink("#{ROOT_PATH}/uploader.pid") }
    end
    layout = Layout.new(File.join(VIEW_PATH,'layout.default.html.erb'))
    uploader = Rack::URLMap.new('/'  => Uploads.new(layout), '/upload' => Uploads.new(layout))
    Thin::Server.start('0.0.0.0', @port, uploader)
  end
end

if $0 == __FILE__
  App.load_dependencies
  app = App.new
  app.execute
end
