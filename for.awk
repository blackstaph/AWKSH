BEGIN {

goofies["baz"] = 1
goofies["bar"] = 3
goofies["bip"] = 42

 for ( i in goofies )  {

   if ( "pizza" in goofies ) {
     print "yep, it's there"
   }
 }

}
