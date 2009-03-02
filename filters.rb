require 'uri'
require 'md5'

#
# Run after the file has been uploaded, this is used to 
# notify another web application of the local file system path
# for where the newly uploaded file may be accessed.
# if the filter is not used, the normal 200 response would be returned
# to the client
#
module Filter
  class Hook
    def initialize(url)
      @url = url
      @auth_host = URI.parse(url).host
    end

    def self.dependencies
      ['curb']
    end

    # send both the filepath and the etag
    def apply(filepath, cookies)
      curl = Curl::Easy.new(@url)
      curl.headers["Cookie"] = cookies
      curl.headers["Host"]   = @auth_host
      curl.headers["Etag"]   = Digest::MD5.hexdigest(File.read(filepath,20))
      curl.http_post(Curl::PostField.content('new_file_path', filepath))
      # parse out the header responses
      header_str = curl.header_str.sub(/.*\r\n/,'')
      header_lines = header_str.split(/\r\n/)
      headers = {}
      header_lines.each do|line|
        key = line.gsub(/:.*$/,'')
        value = line.sub(/.*: /,'')
        headers[key] = value unless key.match(/Content-Length|Connection/)
      end
      [curl.response_code, headers, curl.body_str]
    end
  end
end
