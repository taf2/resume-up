require 'uri'

module Access
  class Authorizer
    def initialize(auth_url,no_auth_redirect)
      @auth_url = auth_url.freeze
      @auth_host = URI.parse(auth_url).host
      @no_auth_redirect = no_auth_redirect
    end

    def self.dependencies
      ['curb']
    end

    def redirect
      if @no_auth_redirect.nil?
        [403, {"Content-Type" => "text/plain"}, "Permission denied"]
      else
        [303, {"Location" => @no_auth_redirect}, ""]
      end
    end

    def authorized?(cookies)
      curl = Curl::Easy.new(@auth_url) do |c| 
        c.headers["Cookie"] = cookies
        c.headers["Host"] = @auth_host
        #c.verbose = true
      end
      curl.perform
      (curl.body_str == "allowed")
    end

  end
end
