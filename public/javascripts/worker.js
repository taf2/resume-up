//
// this is the worker that is going to do the actual file uploading
//
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
// it doesn't loose track of the file, that was partially or not uploaded to the server. in the event it's partially
// uploaded it needs to check with the server and resume sending the file
//
UploadRequet = function(id, file, pool, workerId) {
  this.id   = id;
  this.file = file;
  this.pool = pool;
  this.workerId = workerId;
  //this.chunkSize = 1024; //this.chunkSize = 1024*1024; // 1 MB, using smaller for testing
  this.chunkSize = 1024 * 1024;
  this.byteOffset = 0;
  this.totalSize = this.file.blob.length;
  this.bytesToSend = this.totalSize;
}
UploadRequet.prototype = {
  begin: function() {
    // send the initial message to initialize the file upload
    this.request = google.gears.factory.create('beta.httprequest');

    this.sendProgress(this.file.name, 0.0);

    this.request.open("POST", "/upload?filename="+this.file.name);
    this.request.onreadystatechange = this.trackRequest.bind(this, this.fetchedEtag.bind(this));
    this.request.setRequestHeader("Content-Range", "bytes */" + this.totalSize);
    this.request.send(); // send no body, to get the initial etag
  },
  sendProgress: function( status, offsetByte )
  {
    var progress = offsetByte / this.totalSize;
    this.pool.sendMessage({id: this.id, status:status, progress:progress, filename: this.file.name}, this.workerId);
  },
  //sendStatus: function( status ) {
 //   this.pool.sendMessage({id: this.id, status:status, filename: this.file.name}, this.workerId);
  //},
  // stage 1 complete, we have the etag to idendify the upload
  fetchedEtag: function(status, offsetByte)
  {
    this.tagId = this.request.getResponseHeader("etag");
    //this.sendStatus("got etag response: " + this.tagId );
    //this.sendProgress(this.file.name, this.byteOffset);

    this.sendPart(status, offsetByte);
  },
  sendPart: function(status, offsetByte)
  {
    if( status == 200 ) {
      this.uploadCompleted();
      return;
    }

    // slow it down...
    //for( var i = 0; i < 10000000; ++i ) {
    //}

    // now we send the If-Match: "this.tagId" and the 
    // Content-Range: offsetByte + '-' + (offsetByte + (length-1)) + '/' + this.totalSize;
    
    // create a new request object
    this.request = google.gears.factory.create('beta.httprequest');
    this.request.open("POST", "/upload");
    this.request.onreadystatechange = this.trackRequest.bind(this, this.sendPart.bind(this));
    this.request.setRequestHeader("If-Match", this.tagId);
    var length = this.chunkSize;

    // compute next content length or chunk size
    if( this.chunkSize > this.bytesToSend ) { // if chunk size is greater then what we have left to send use bytesToSend
      length = this.bytesToSend; 
      this.bytesToSend = 0;
    }
    else {
      this.bytesToSend -= this.chunkSize;
    }

    // can't set this header, xhr does it for us... good thing we can set the range header
    //this.request.setRequestHeader("Content-Length", length );
    var range = offsetByte + "-" + (offsetByte + (length - 1)) + "/" + this.totalSize;
    this.request.setRequestHeader("Content-Range", range);
    this.request.onprogress = this.onProgress.bind(this);

    //this.sendStatus("for: " + this.tagId + ", computed offset: " + this.byteOffset + ", server requested offset: " + offsetByte);
    this.sendProgress(this.file.name, offsetByte);
    // slice the blob

    var part = this.file.blob.slice(offsetByte,length); // use the server offset
    this.byteOffset += length;
    this.request.send(part); // send no body, to get the initial etag
  },
  onProgress: function(pevent)
  {
    this.sendProgress(this.file.name, this.byteOffset + pevent.loaded );
    //this.sendStatus("request progress:" + pevent.loaded + "/" + pevent.total );
  },
  uploadCompleted: function() 
  {
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
  }
};

// when a message is recieved start uploading the file
// report back on progress to our parent
google.gears.workerPool.onmessage = function(a, b, message) {
  google.gears.workerPool.sendMessage({id: message.body.id, status:"Recieved message: " + message.body.file.name}, message.sender);
  var uploader = new UploadRequet(message.body.id, message.body.file, google.gears.workerPool, message.sender);
  uploader.begin();
}
