//
// Worker process: handles sending a file in smallish chunks using 
// many xhr requests.
//
// Author: Todd A. Fisher <todd.fisher@gmail.com>
//
/**** proto lite : see http://prototypejs.org/ **/
Object.extend = function(destination, source) {
  for (var property in source)
    destination[property] = source[property];
  return destination;
};
Object.extend(Object, {
  isUndefined: function(object) {
    return typeof object == "undefined";
  }
});

Object.extend(Function.prototype, {
  bind: function() {
    if (arguments.length < 2 && Object.isUndefined(arguments[0])) return this;
    var __method = this, args = $A(arguments), object = args.shift();
    return function() {
      return __method.apply(object, args.concat($A(arguments)));
    }
  }
});
function $A(iterable) {
  if (!iterable) return [];
  if (iterable.toArray) return iterable.toArray();
  var length = iterable.length, results = new Array(length);
  while (length--) results[length] = iterable[length];
  return results;
}
//********* end proto lite ****/

//
// Worker needs to save some meta data about the file in storage so if the browser is closed during an upload
// it doesn't loose track of the file, that was partially or not uploaded to the server. In the event it's partially
// uploaded, it needs to check with the server and resume sending the file, from where the server reports in it's Range header.
//
// Files are sent using the chunkSize defined below.
//
UploadRequet = function(id, file, pool, workerId) {
  this.id   = id; // identifier for this upload
  this.file = file; // the file to upload
  this.pool = pool; // the worker pool this transaction belongs too
  this.workerId = workerId; // the worker id within the worker pool
  this.chunkSize = 1024 * 1024; // send files in 1 MB chunk size
  this.byteOffset = 0; // track the current byte offset in this.file
  this.totalSize = this.file.blob.length; // total bytes to transfer of this.file
  this.bytesToSend = this.totalSize; // how many more bytes to send, default is the totalSize
}
UploadRequet.prototype = {
  //
  // begin the file upload transaction
  //
  // Client sends initial handshake:
  // 
  // POST /upload HTTP/1.1
  // Host: example.com
  // Content-Length: 0
  // Content-Range: bytes */100
  //
  // this is how we get our upload identifier
  // the server is expected to respond with an Etag identifier such as below:
  //
  // HTTP/1.1 308 Resume Incomplete
  // ETag: "vEpr6barcD"
  // Content-Length: 0
  //
  // if the uploader already hasa this.tagId e.g. the ETag for an existing upload
  // and this is called, it's like doing a status check
  // and will trigger uploadPart from the servers reported offsetByte
  //
  begin: function() {
    // send the initial message to initialize the file upload
    this.request = google.gears.factory.create('beta.httprequest');


    this.request.open("POST", "/upload?filename="+this.file.name);

    // when the request completes call fetchedEtag, to continue the upload flow
    this.request.onreadystatechange = this.trackRequest.bind(this, this.fetchedEtag.bind(this));
    this.request.setRequestHeader("Content-Range", "bytes */" + this.totalSize);
    if( this.tagId ) {
      // set the If-Match: "this.tagId"
      this.request.setRequestHeader("If-Match", this.tagId);
    }
    else {
      this.sendProgress(this.file.name, 0.0);
    }

    this.request.send(); // send no body, to get the initial etag
  },
  sendProgress: function( status, offsetByte )
  {
    var progress = offsetByte / this.totalSize;
    this.pool.sendMessage({type:'progress', id: this.id, status:status, progress:progress, filename: this.file.name}, this.workerId);
  },
  sendError: function( status )
  {
    this.pool.sendMessage({type:'error', id: this.id, status:status, filename: this.file.name}, this.workerId);
  },
  // 
  // We received the resume response from the server 
  //
  // HTTP/1.1 308 Resume Incomplete
  // ETag: "vEpr6barcD"
  // Content-Length: 0
  //
  // Next we can start uploading bytes to the server
  //
  fetchedEtag: function(status, offsetByte)
  {
    if( status == 308 ) {
      this.tagId = this.request.getResponseHeader("etag");
      this.sendPart(status, offsetByte);
    }
    else if( status == 200 ) {
      this.onError("Server reported file uploaded");
    }
    else {
      this.onError("Unexpected Server Response: " + status);
    }
  },
  // 
  // send this.chunkSize bytes to the server
  //
  // slices the file blob into a smaller blob starting at the given offsetByte, to this.chunkSize
  // if this.chunkSize + offsetByte is greater then the end of the blob, the max length of the blob
  // is used as the end of the slice.
  //
  // an XHR request is created with the Content-Range header set to the offsetByte-ByteLength/TotalSize
  //
  // offsetByte: is provided by the server.
  // ByteLength: is computed from the offsetByte, chunkSize, and total size
  // TotalSize: is computed from the the file.blob.length
  //
  // on successful upload, e.g. a server response of 200
  //  this.uploadCompleted is called
  //
  sendPart: function(status, offsetByte)
  {
    if( status == 200 ) {
      this.uploadCompleted();
      return;
    }

    // slow it down...
    //for( var i = 0; i < 10000000; ++i ) {
    //}


    // keep the length within the bounds of the file.blob.length
    var length = this.chunkSize;
    // clamp the length to make sure it doesn't exceed the totalSize
    if( (offsetByte + length) > this.totalSize ) {
      length = this.totalSize - offsetByte; // clamp
    }
 
    // create a new request object
    this.request = google.gears.factory.create('beta.httprequest');
    this.request.open("POST", "/upload");
    this.request.onreadystatechange = this.trackRequest.bind(this, this.sendPart.bind(this));

    // set the If-Match: "this.tagId"
    this.request.setRequestHeader("If-Match", this.tagId);

    // Content-Range: offsetByte + '-' + (offsetByte + (length-1)) + '/' + this.totalSize;
    var range = offsetByte + "-" + (offsetByte + length ) + "/" + this.totalSize;
    this.request.setRequestHeader("Content-Range", range);

    // listen for network activity, this way we can update the UI thread when while chunkSize is transferring
    this.request.onprogress = this.onProgress.bind(this);

    //this.sendStatus("for: " + this.tagId + ", computed offset: " + this.byteOffset + ", server requested offset: " + offsetByte);
    this.sendProgress(this.file.name, offsetByte);

    try { // Any operation involving a Blob may throw an exception.

      // slice the blob
      var part = this.file.blob.slice(offsetByte,length); // use the server offset

      // compute the offset 
      this.byteOffset += length;

      // send the part
      this.request.send(part);

    } catch( e ) {
      this.onError(e);
    }
  },
  onProgress: function(pevent)
  {
    this.sendProgress(this.file.name, this.byteOffset + pevent.loaded );
  },
  onError: function(error)
  {
    if( this.request ) {
      try{ this.request.abort(); } catch(e) {} // try to abort
      this.request = null;
    }
    this.sendError(this.file.name + ": " + error );
  },
  uploadCompleted: function() 
  {
    this.request = null;
    this.completed = true;
    this.sendProgress(this.file.name, this.totalSize );
  },
  trackRequest: function(callback)
  {
    //this.sendStatus(" - for: [" + this.tagId + "] readyState: " + this.request.readyState );
    if( this.request.readyState == 4 ) {
      var status = this.request.status;
      //this.sendStatus(status + " - for: [" + this.tagId + "] headers: " + this.request.getAllResponseHeaders() );
      var range = this.request.getResponseHeader("Range");
      if( range ) {
        // parse the last range byte e.g. 0-#{number}
        offset = parseInt(range.replace(/[0-9]+-/,''));
        //this.sendStatus("for: [" + this.tagId + "] offset: " + offset );
        callback(status,offset);
      }
      else {
        callback(status,0);
      }
    }
  },
  pause: function()
  {
    if( this.completed ) { return; } // if completed do nothing
    if( this.request ) {
      this.request.abort();
      this.request = null;
    }
  },
  resume: function()
  {
    if( this.completed ) { return; } // if completed do nothing
    if( this.request ) { return; } // if request is not paused do nothing
    // start the resume process, similar to begin, but send the ETag in the request
    this.begin();
  }
};

// keep track of all running uploads
UploadManager = function() {
  this.uploads = []; // UploadRequest objects indexed by id
};
UploadManager.prototype = {
  addUpload: function(uploadRequest, id) {
    this.uploads[id] = uploadRequest;
  }
};
var uploadManager = new UploadManager();

//
// Monitor messages from the UI Thread
// 
// upload:new
//   - create a new uploader and start sending the bytes
//   - requires uploader id and fileBlob to upload
//
// upload:pause
//   - pause an active upload
//   - requires uploader id
//
// upload:resume
//   - resume a paused upload
//   - requires uploader id
// 
google.gears.workerPool.onmessage = function(a, b, message) {
  var type = message.body.type;
  var id = message.body.id;
  //google.gears.workerPool.sendMessage({id: id, status:"Recieved message: " + type}, message.sender);
  switch( type ) {
  case "upload:new":
    var uploader = new UploadRequet(id, message.body.file, google.gears.workerPool, message.sender);
    uploader.begin();
    uploadManager.addUpload(uploader,id);
    break;
  case "upload:pause":
    var upload = uploadManager.uploads[id];
    if( upload ) {
      upload.pause();
    }
    else {
      // error
      google.gears.workerPool.sendMessage({id: message.body.id, status:"Received pause message, but could not find uploader for " + id}, message.sender);
    }
    break;
  case "upload:resume":
    var upload = uploadManager.uploads[id];
    if( upload ) {
      upload.resume();
    }
    else {
      // error
      google.gears.workerPool.sendMessage({id: message.body.id, status:"Received resume message, but could not find uploader for " + id}, message.sender);
    }
    break;
  default:
    break;
  }
}
