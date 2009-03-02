require 'uri'

#
# Determine authentication by forwarding all the request headers
# to a auth_url
#
# the auth_url is expected to respond with either
#
# allowed, meaning the user is authenticated
# or
# denied, meaning the user is not authenticated or not valid
#
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
      curl = Curl::Easy.new(@auth_url)
      curl.headers["Cookie"] = cookies
      curl.headers["Host"]   = @auth_host
      curl.perform
      (curl.body_str == "allowed")
    end

  end
end
