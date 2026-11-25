rodriextract
============
Pulls the pictures out of PDF files, at the best quality the PDF allows.
Nothing to install. No administrator rights needed.

HOW TO USE
----------
1. If you got this as a zip file: right-click it, choose "Extract All...", and open
   the new folder. (Don't run it from inside the zip.)
2. Double-click  rodriextract.cmd  (a window opens after a second or two).
3. Choose a PDF (or several), or a whole folder of PDFs.
   You can also drag PDFs or a folder onto the window.
4. Pick the smallest image size you care about. 300 x 300 is a good start;
   it skips icons, bullets and tiny logos.
5. Click "Extract images".

WHERE ARE MY IMAGES?
--------------------
Next to each PDF you'll find a new folder named after it, e.g.
    Report.pdf   ->   Report_images\
Files are named by page: page003_image01.jpg, page003_image02.png ...
Running it again never overwrites earlier results; it makes Report_images_2, etc.

QUALITY
-------
Images are copied out exactly as stored in the PDF - JPEGs are not re-compressed.
Other image types are saved as lossless PNG.

IF SOMETHING GOES WRONG
-----------------------
- Nothing happens / the window flashes and closes: double-click rodriextract-visible.cmd
  instead. It keeps a black window open that shows the error message.
- Still not working: open the "diagnostic" folder, double-click rodriextract-diagnose.cmd,
  wait for it to finish, and send the report file it shows you.
- "Can't find its poppler folder": extract the whole zip first and keep all files together.
- Windows says the app is blocked: ask your IT team to allow scripts in this folder.
- Password-protected or damaged PDFs are skipped, and the rest carry on.
- A log is kept at  %LOCALAPPDATA%\rodriextract\rodriextract.log

ABOUT
-----
rodriextract is two plain text files (rodriextract.cmd and rodriextract.ps1) that you can
open in Notepad to see exactly what they do, plus the free Poppler tools in the "poppler"
folder (GPL licensed, see poppler\README-poppler.txt).
