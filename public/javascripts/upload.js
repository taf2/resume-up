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
    this.fileList = this.form.down(".selected-files");
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
  //
  // receive messages from workers
  //  - progress: refresh the UI with new progress
  //  - error: report errors sent from workers
  //
  messageCallback: function(a, b, message ) {
    switch(message.body.type) {
    case 'progress':
      this.uploadProgress(message);
      break;
    case 'error':
      this.uploadError(message,true);
      break;
    case 'complete':
      this.uploadComplete(message);
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
  uploadComplete: function(message) {
    var id = message.body.id;
    var fileData = this.files[id];
    var li = fileData.li;
    li.innerHTML = "Completed: " + fileData.file.name;
  },
  selectedFiles: function(files) {
    this.files = [];
    var progressFrame = $("progress-frame").innerHTML;

    for( var i = 0, len = files.length; i < len; ++i ) {
      var file = files[i];

      var li = $(document.createElement("li"));
      li.innerHTML = progressFrame;
      li.down(".rtp").innerHTML = file.name + ": 0%";
      li.down(".progress-frame").style.display = "";

      // attach listener for pause button
      var pauseResumeButton = li.down(".upload-pause-resume");
      pauseResumeButton.observe("click", this.pauseResume.bindAsEventListener(this, pauseResumeButton,i));

      this.fileList.appendChild(li);
      this.files.push( {li:li, file: files[i]} ); // track the file
      this.workerPool.sendMessage({type:"upload:new", file: file, id: i}, this.workerId);
    }
  }, 
  //
  // user clicked the pause or resume button
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
Object.extend(FileSelector, {
  //
  // create the file selector form
  // once the DOM is ready create the selector object
  // and call the createdCB if it's defined
  //
  create: function(createdCB) {
    // write the form to the dom
    var doc = document;
    doc.write( '<div id="upload-forms">' );
      doc.write( '<div id="progress-frame">' );
        doc.write( '<div class="progress-frame" style="display:none">' );
          doc.write( '<div class="progress" style="margin-bottom:10px; margin-right:10px; float:left; width: 402px; border: 1px solid #CEE1EF">' );
            doc.write( '<div class="bar" style="width: 1px; background-color: #CEE1EF; border: 1px solid white">' );
              doc.write( '<div class="tp"></div>' );
              doc.write( '<div style="text-align:center;width:400px;" class="rtp">0%</div>' );
            doc.write( '</div>' );
          doc.write( '</div>' );
          doc.write( '<input type="button" class="upload-pause-resume" value="Pause"/>' );
          doc.write( '<div class="clear"></div>' );
        doc.write( '</div>' );
      doc.write( '</div>' );

      doc.write( '<form id="upload-form" action="/upload" method="post">' );
        doc.write( '<fieldset>' );
          doc.write( '<h3>Uploads</h3>' );
          doc.write( '<ul class="selected-files"></ul>' );
          doc.write( '<div class="controls">' );
            doc.write( '<input class="file-input" type="button" name="new_file_path" value="Select files"/>' );
          doc.write( '</div>' );
        doc.write( '</fieldset>' );
      doc.write( '</form>' );
    doc.write( '</div>' );

    // now wait for things to be ready
    document.observe("dom:loaded", function() {
      var selector = new FileSelector($("upload-form"));
      if( createdCB && Object.isFunction(createdCB) ) {
        createdCB(selector);
      }
    });
  }
} );
