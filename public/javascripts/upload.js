//
// User selects multiple files, Sees a progress bar for each file.
// In background worker pool, each file is uploaded in many small chunks.
// A server process will handle piecing the files back together 
// This implementation was inspired by:
// http://code.google.com/p/gears/wiki/ResumableHttpRequestsProposal
//
// Author: Todd A. Fisher <todd.fisher@gmail.com>
//
FileSelector = Class.create({
  initialize: function(form) {
    this.form = form;
    this.files = [];
    this.filter = []; //'text/plain', '.html'];
    this.form.down(".file-input").observe("click", this.selectFiles.bindAsEventListener(this));
    //this.form.down(".button.send").observe("click", this.sendFiles.bindAsEventListener(this));
    this.selectFiles = this.form.down(".selected-files");
    this.uploads = [];

    // create  worker pool to distribute each request too
    this.workerPool = google.gears.factory.create('beta.workerpool');
    this.workerPool.onmessage = this.messageCallback.bind(this);
    this.workerId = this.workerPool.createWorkerFromUrl("/javascripts/worker.js");
  },
  //
  // User clicked select files
  //  - opens the multiple select file picker using the currently selected filters
  //
  selectFiles: function(e) {
    var desktop = google.gears.factory.create('beta.desktop');
    desktop.openFiles(this.selectedFiles.bind(this), { filter: this.filter });
  },
  messageCallback: function(a, b, message ) {
    switch(message.body.type) {
    case 'progress':
      this.uploadProgress(message);
      break;
    case 'error':
      this.uploadError(message,true);
      break;
    default:
      this.uploadError(message,false);
      break;
    }
  },
  uploadError: function(message, expected)
  {
    console.error(message.body);
    console.error(message.body.status);
  },
  //
  // display progress events
  //   - worker.js sends these messages to notify us of the current upload status
  //
  uploadProgress: function(message) {
    var id = message.body.id;
    var progress = message.body.progress;
    //console.log("(" + message.body.id + ")uploading: " + message.body.status + " percent complete: " + progress );
    var fileData = this.files[id];
    var li = fileData.li;
    var max = parseInt(li.down(".progress").style.width) - 2;
    var bar = li.down(".bar");
    var status = li.down(".rtp");
    var percent = Math.round(progress*100);
    bar.style.width = (progress * max) + "px";

    status.innerHTML = fileData.file.name + " (" + percent + "%)";
  },
  selectedFiles: function(files) {
    this.files = [];
    var progressFrame = $("progress-frame").innerHTML;
    for( var i = 0, len = files.length; i < len; ++i ) {
      var file = files[i];
      //console.log(file.name);
      var li = document.createElement("li");
      li.innerHTML = progressFrame;
      li.down(".rtp").innerHTML = file.name + ": 0%";
      li.down(".progress-frame").style.display = "";
      // attach listener for pause button
      var pauseResumeButton = li.down(".upload-pause-resume");
      pauseResumeButton.observe("click", this.pauseResume.bindAsEventListener(this, pauseResumeButton,i));
      this.selectFiles.appendChild(li);
      this.files.push( {li:li, file: files[i]} ); // track the file
      this.workerPool.sendMessage({type:"upload:new", file: file, id: i}, this.workerId);
    }
  }, 
  //
  // user clicked the pause button
  //
  pauseResume: function(e,button,id)
  {
    //console.log("pause:" + button + ", " + id);
    if( button.value == "Pause" ) { // send pause
      button.value = "Resume";
      this.workerPool.sendMessage({type:"upload:pause", id: id}, this.workerId);
    } else { // send resume
      button.value = "Pause";
      this.workerPool.sendMessage({type:"upload:resume", id: id}, this.workerId);
    }
  }
});

document.observe("dom:loaded", function() {
  var selector = new FileSelector($("upload-form"));
});
