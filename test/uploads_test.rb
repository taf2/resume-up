require 'test/unit'
require File.join(File.dirname(File.expand_path(__FILE__)), "..", "uploader.rb")
App.load_dependencies
require 'ostruct'
#gem 'mocha'
#require 'mocha'

class UploadsTest < Test::Unit::TestCase
  def setup
    @layout = Layout.new(File.join(VIEW_PATH,'layout.default.html.erb'))
    @uploader = Uploads.new(@layout)
  end

  def test_generated_keys_are_unique
    keys = {}
    100.times do # quick check - no where near 100%
      key = @uploader.send(:unique_key,"test")
      assert !keys.key?(key)
      keys[key] = true
    end
  end

  def test_upload_path_path_exists
    key = @uploader.send(:unique_key, "test")
    filepath = @uploader.send(:upload_path, key)
    assert File.exist?(File.dirname(filepath))
  end

  def test_upload_initiate_creates_file
    moch_request = OpenStruct.new({:params => {'filename' => "test"}})   
    status, headers, body = @uploader.send(:upload_initiate, moch_request)
    assert_equal 308, status
    assert headers.key?('ETag')
    assert !headers['ETag'].empty?
    upload_file = @uploader.send(:upload_path, headers['ETag'])
    assert File.exist?(upload_file)
    assert_equal 0, File.size(upload_file)
    assert body.empty?

    # cleanup
    assert File.unlink(upload_file)
  end

  def test_upload_part
    send_body = "xxxxxxxxxxxxxxxxxxxxxxxx"
    moch_request = OpenStruct.new({:params => {'filename' => "test"}, :body => StringIO.new(send_body) })
    range = "0-#{send_body.size}/#{send_body.size*2}" # pretend like we have 2x more to send
    env = {"HTTP_CONTENT_RANGE" => range}

    # send the initiate request
    status, headers, body = @uploader.send(:upload_initiate, moch_request)
    key = headers['ETag']
    upload_file = @uploader.send(:upload_path, key)
    assert File.exist?(upload_file)
    assert_equal 0, File.size(upload_file)
    assert body.empty?

    # send the first part request with smaller body then range given
    status, headers, body = @uploader.send(:upload_part, key, upload_file, moch_request, env)
    assert_equal 308, status
    assert_equal key, headers['ETag']
    assert_equal "0-#{send_body.size}", headers['Range']
    assert body.empty?
    assert_equal send_body, File.read(upload_file)

    moch_request = OpenStruct.new({:params => {'filename' => "test"}, :body => StringIO.new(send_body) })
    range = "#{send_body.size}-#{send_body.size*2}/#{send_body.size*2}" # send the final chunk
    env = {"HTTP_CONTENT_RANGE" => range}
    status, headers, body = @uploader.send(:upload_part, key, upload_file, moch_request, env)
    assert_equal 200, status
    assert_equal key, headers['ETag']
    assert_equal "uploaded: #{upload_file}", body
    assert_equal send_body*2, File.read(upload_file)

    # cleanup
    assert File.unlink(upload_file)
  end

end
