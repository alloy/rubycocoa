# -*-rd-*-
= Try RubyCocoa Samples

Let's try scripts and applications of samples.

== RubyCocoa Application

First, try to execute a RubyCocoa application which has already
builded. In Finder, open '/Developer/Examples/RubyCocoa' folder and
double click SimpleApp.  Or type following on command line:

  % cd /Developer/Examples/RubyCocoa
  % open SimpleApp.app


== on command line (Terminal)

You can write a script for command line with RubyCocoa.  Now, let's
try to execute a simple script in sample directory.

  % cd /Developer/Examples/RubyCocoa
  % ruby fontnames.rb # fontname print to stdout.
  % ruby sndplay.rb   # system sounds play in order.
  % ruby sndplay2.rb  # system sounds play in order with short interval.

For Mac OS X 10.2 users, furthermore:

  % echo Hello World | ruby speak.rb
  % head -5 speak_me.txt | ruby speak.rb

This will be interesting. When execute speak.rb without argument, Mac
read an each line text you typed out until input 'control-D'.  In
these script, it's used AppleScript (and AppleEvent) interface which
have implemented since Mac OS X 10.2.

Next, try scripts with windowing.

  $ ruby HelloWorld.rb                       # window and buttons
  $ ruby TransparentHello.rb                 # transparency!
  $ (cd Hakoiri-Musume && ruby rb_main.rb )  # puzzle game


== Build a Makefile based RubyCocoa application

Next one is Makefile based. Type to build: 

  % cd /Developer/Examples/RubyCocoa/Hakoiri-Musume
  % make

And launch application:

  % open CocoHako.app

or double click 'CocoHako' on Finder. 


== Build a Project Builder based RubyCocoa application

Next one is Project Builder based. type to build:

  % cd /Developer/Examples/RubyCocoa/simpleapp
  % pbxbuild
  % open build/SimpleApp.app

You can build and run the application in Project Builderm, too. Launch
application:


== Next...

There are the other various samples. Please read and try them. Have a
fun!


== supplement

* HelloWorld.rb is a sample script for ((<PyObjc|URL:http://pyobjc.sf.net/>))
  that was translated from Python into Ruby.

* TransparentHello.rb appear in the article of
  ((<'Dr.Dobbs Journal, May 2002'|URL:http://http://www.ddj.com/articles/2002/0205//>))
  written by Chris Thomas.

* RubyRaiseMan and RubyTypingTutor is a tutorial application in
  ((<'Mac OS X Cocoa Programming'|URL:http://www.amazon.com/exec/obidos/tg/detail/-/0201726831>))
  that was translated from Objective-C into Ruby.

* MyViewer is a sample in Japanese book
  ((<'guide of Mac OS X Programming - Objective-C'|URL:http://www.amazon.co.jp/exec/obidos/ASIN/4877780688>))
  that was translated from Objective-C into Ruby.


$Date$
