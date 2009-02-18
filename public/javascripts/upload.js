//
// we're going to send the file in small chunks, so we'll be using many 
// xhr requests, the server will handle piecing the files back together 
// this is a naive implemenation of what is described here:
// http://code.google.com/p/gears/wiki/ResumableHttpRequestsProposal
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
    this.workerPool.onmessage = this.uploadProgress.bind(this);
    this.workerId = this.workerPool.createWorkerFromUrl("/javascripts/worker.js");
  },
  selectFiles: function(e) {
    var desktop = google.gears.factory.create('beta.desktop');
    desktop.openFiles(this.selectedFiles.bind(this), { filter: this.filter });
  },
  uploadProgress: function(a, b, message) {
    var id = message.body.id;
    var progress = message.body.progress;
    console.log("(" + message.body.id + ")uploading: " + message.body.status + " percent complete: " + progress );
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
      console.log(file.name);
      var li = document.createElement("li");
      li.innerHTML = progressFrame;
      li.down(".rtp").innerHTML = file.name + ": 0%";
      li.down(".progress-frame").style.display = "";
      this.selectFiles.appendChild(li);
      this.files.push( {li:li, file: files[i]} ); // track the file
      this.workerPool.sendMessage({file: file, id: i}, this.workerId);
    }
  }
});

document.observe("dom:loaded", function() {
  var selector = new FileSelector($("upload-form"));
});
