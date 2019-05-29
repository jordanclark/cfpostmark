component {

	function init(
		required string apiKey
	,	string spoolDir= "ram:///postmark"
	,	string defaultFrom= ""
	,	string defaultReplyTo= ""
	,	string defaultBCC= ""
	,	boolean compress= false
	,	boolean debug= false
	,	numeric httpTimeOut= 120
	) {
		this.apiUrl= "https://api.postmarkapp.com/";
		this.httpTimeOut= arguments.httpTimeOut;
		this.compress= arguments.compress;
		this.debug= arguments.debug;
		if ( structKeyExists( request, "debug" ) && request.debug == true ) {
			this.debug= request.debug;
		}
		this.addRack(
			rack= "default"
		,	apiKey= arguments.apiKey
		,	spoolDir= arguments.spoolDir
		,	compress= arguments.compress
		);
		this.bounceTypes= [
			"HardBounce"
		,	"Transient"
		,	"Unsubscribe"
		,	"Subscribe"
		,	"AutoResponder"
		,	"AddressChange"
		,	"DnsError"
		,	"SpamNotification"
		,	"OpenRelayTest"
		,	"Unknown"
		,	"SoftBounce"
		,	"VirusNotification"
		,	"ChallengeVerification"
		,	"BadEmailAddress"
		,	"SpamComplaint"
		,	"ManuallyDeactivated"
		,	"Unconfirmed"
		,	"Blocked"
		];
		this.blankMail= {
			"To"= ""
		,	"Bcc"= arguments.defaultBCC
		,	"From"= arguments.defaultFrom
		,	"ReplyTo"= arguments.defaultReplyTo
		,	"Subject"= ""
		,	"HtmlBody"= ""
		,	"TextBody"= ""
		,	"Tag"= ""
		};
		return this;
	}

	function debugLog( required input ) {
		if ( structKeyExists( request, "log" ) && isCustomFunction( request.log ) ) {
			if ( isSimpleValue( arguments.input ) ) {
				request.log( "Postmark: " & arguments.input );
			} else {
				request.log( "Postmark: (complex type)" );
				request.log( arguments.input );
			}
		} else if( this.debug ) {
			cftrace( text=( isSimpleValue( arguments.input ) ? arguments.input : "" ), var=arguments.input, category="Postmark", type="information" );
		}
		return;
	}

	string function htmlCompressFormat(required string html) {
		return reReplace( arguments.html, "[[:space:]]{2,}", chr( 13 ), "all" );
	}

	function addRack( required string rack, required string apiKey, string spoolDir= "ram:///postmark-#arguments.rack#", boolean compress= true ) {
		this.rack[ arguments.rack ]= {
			apiKey= arguments.apiKey
		,	spoolDir= arguments.spoolDir
		,	secure= arguments.secure
		,	compress= arguments.compress
		};
		if ( len( arguments.spoolDir ) && !directoryExists( arguments.spoolDir ) ) {
			directoryCreate( arguments.spoolDir );
		}
		return;
	}

	struct function getBlankMail() {
		var mail= duplicate( this.blankMail );
		structAppend( mail, arguments, true );
		return mail;
	}

	/*
	 * mail structure
	 * - subject
	 * - htmlBody
	 * - textBody
	 * - from
	 * - replyTo
	 * - to
	 * - bcc
	 * - tag
	 */	
	struct function sendMail( required struct mail, boolean spool= false, string send= true, string rack= "default" ) {
		var thisRack= this.rack[ arguments.rack ];
		var out= {
			success= false
		};
		var args= {
			"To"= arguments.mail.to
		,	"Bcc"= arguments.mail.bcc
		,	"From"= arguments.mail.from
		,	"ReplyTo"= arguments.mail.replyTo
		,	"Subject"= arguments.mail.subject
		,	"HtmlBody"= arguments.mail.htmlBody
		,	"TextBody"= arguments.mail.textBody
		,	"Tag"= ( arguments.mail.tag ?: "" )
		};
		var json= "";
		if ( structKeyExists( arguments.mail, "headers" ) ) {
			args[ "Headers" ]= arguments.mail.headers;
		}
		if ( thisRack.compress ) {
			args[ "HtmlBody" ]= this.htmlCompressFormat( args.HtmlBody );
		}
		json= serializeJSON( args );
		this.debugLog( "!!Send mail with postmark to #arguments.mail.to#" );
		this.debugLog( args );
		if ( arguments.send ) {
			if ( !arguments.spool ) {
				out= this.apiRequest( uri= "email", json= json, rack= arguments.rack );
				if ( !out.success ) {
					arguments.spool= true;
				}
			}
			if ( len( thisRack.spoolDir ) && arguments.spool ) {
				var fn= "#thisRack.spoolDir#/send_#getTickCount()#_#randRange( 1, 10000 )#.json";
				fileWrite( fn, json );
				this.debugLog( "Spooled mail to #fn#" );
				out.success= true;
			}
		}
		return out;
	}

	struct function processSpool( numeric threads= 1, string rack= "default" ) {
		var thisRack= this.rack[ arguments.rack ];
		var json= "";
		var out= {};
		if( !len( thisRack.spoolDir ) ) {
			return out;
		}
		var aMail= directoryList( thisRack.spoolDir, false, "path", "*.json", "DateLastModified", "file" );
		// lucee multithreading
		if( structKeyExists( server, "lucee" ) ) {
			arrayEach( aMail, function( fn ) {
				out[ fn ]= "";
				lock type="exclusive" name="postmark_#fn#" timeout="0" {
					if ( fileExists( fn ) ) {
						json= fileRead( fn );
						if ( len( json ) ) {
							var send= this.apiRequest( uri= "email", json= json, rack= arguments.rack );
							out[ fn ]= ( send.success ? "sent" : "error:" & send.error );
							if( send.success ) {
								fileDelete( fn );
							}
						} else {
							out[ fn ]= "error: empty json file";
						}
					} else {
						out[ fn ]= "error: file #fn# is missing";
					}
				}
			}, ( arguments.threads > 1 ), arguments.threads );
		} else {
			arrayEach( aMail, function( fn ) {
				out[ file ]= "";
				lock type="exclusive" name="postmark_#fn#" timeout="0" {
					if ( fileExists( fn ) ) {
						json= fileRead( fn );
						if ( len( json ) ) {
							var send= this.apiRequest( uri= "email", json= json, rack= arguments.rack );
							out[ fn ]= ( send.success ? "sent" : "error:" & send.error );
							if( send.success ) {
								fileDelete( fn );
							}
						} else {
							out[ fn ]= "error: empty json file";
						}
					} else {
						out[ fn ]= "error: file #fn# is missing";
					}
				}
			};
		}
		return out;
	}

	/**
	 * Fetches a portion of bounces according to the specified input criteria. Supported filters: type, inactive, email like, tag.
	 */
	function getBounces( string type= "", string inactive= "", string emailFilter= "", string tag= "", numeric start= 0, numeric limit= 25, string rack= "default" ) {
		var out= this.apiRequest(
			uri= "bounces"
		,	type= arguments.type
		,	emailFilter= arguments.emailFilter
		,	tag= arguments.tag
		,	offset= arguments.start
		,	count= arguments.limit
		,	rack= arguments.rack
		);
		return out;
	}

	/**
	 * Get details about a single bounce. Note that the bounce ID is a numeric value that you typically obtain after a getting a list of bounces.
	 */
	function getBounce( required string id, string rack= "default" ) {
		var out= this.apiRequest(
			uri= "bounces/#arguments.id#"
		,	rack= arguments.rack
		);
		return out;
	}

	/**
	 * Returns the raw source of the bounce we accepted. If Postmark does not have a dump for that bounce, it will return an empty string.
	 */
	function getBounceDump( required string id, string rack= "default" ) {
		var out= this.apiRequest(
			uri= "bounces/#arguments.id#/dump"
		,	rack= arguments.rack
		);
		return out;
	}

	/**
	 * Activates a deactivated bounce. Note that you do not need to send anything in the request body.
	 */
	function retryBounce( required string id, string rack= "default" ) {
		var out= this.apiRequest(
			uri= "bounces/#arguments.id#/activate"
		,	rack= arguments.rack
		);
		return out;
	}

	/**
	 * Returns a list of tags used for the current server.
	 */
	function getTags( string rack= "default" ) {
		var out= this.apiRequest(
			uri= "bounces/tags"
		,	rack= arguments.rack
		);
		return out;
	}

	/**
	 * Returns a summary of inactive emails and bounces by type
	 */
	function deliveryStats( string rack= "default" ) {
		var i= "";
		var out= this.apiRequest(
			uri= "deliverystats"
		,	rack= arguments.rack
		);
		out.bounces= { "All"= 0 };
		for ( i in this.bounceTypes ) {
			out.bounces[ i ]= 0;
		}
		out.inactive= 0;
		if ( out.success ) {
			for ( i in out.response.bounces ) {
				if ( structKeyExists( i, "Type" ) ) {
					out.bounces[ i.Type ]= i.Count;
				} else {
					out.bounces[ "All" ]= i.Count;
				}
			}
			out.inactive= out.response.InactiveMails;
		}
		return out;
	}

	struct function apiRequest( required string uri, string rack= "default" ) {
		var thisRack= this.rack[ arguments.rack ];
		var http= {};
		var item= "";
		var out= {
			success= false
		,	verb= "GET"
		,	url= this.apiUrl&arguments.uri
		,	error= ""
		,	status= ""
		,	statusCode= 0
		,	response= ""
		};
		structDelete( arguments, "rack" );
		structDelete( arguments, "uri" );
		if ( structKeyExists( arguments, "json" ) ) {
			out.verb= "POST";
		}
		for ( item in arguments ) {
			if ( len( arguments[ item ] ) && item != "json" ) {
				requestUri &= ( find( "?", requestUri ) ? "&" : "?" ) & lCase( item ) & "=" & urlEncodedFormat( arguments[ item ] );
			}
		}
		this.debugLog( "POSTMARK: #out.verb# #requestUri#" );
		if ( this.debug ) {
			this.debugLog( duplicate( arguments ) );
		}
		cfhttp( result="http", method=out.verb, url=requestUri charset="utf-8", throwOnError=false, timeOut=this.httpTimeOut ) {
			cfhttpparam( name="Accept", type="header", value="application/json" );
			cfhttpparam( name="Content-Type", type="header", value="application/json" );
			cfhttpparam( name="X-Postmark-Server-Token", type="header", value=thisRack.apiKey );
			if ( structKeyExists( arguments, "json" ) && len( arguments.json ) ) {
				cfhttpparam( type="body", value=arguments.json );
			}
		}
		out.response= toString( http.fileContent );
		//  RESPONSE CODE ERRORS 
		if ( !structKeyExists( http, "responseHeader" ) || !structKeyExists( http.responseHeader, "Status_Code" ) ) {
			out.error= "No response header returned";
		} else {
			out.statusCode= http.responseHeader[ "Status_Code" ];
		}
		this.debugLog( out.response );
		//  RESPONSE CODE ERRORS 
		if ( out.statusCode == "401" ) {
			out.error= "401 unauthorized";
		} else if ( out.statusCode == "422" ) {
			out.error= "422 unprocessable";
		} else if ( out.statusCode == "500" ) {
			out.error= "500 server error";
		} else if ( listFind( "4,5", left( out.statusCode, 1 ) ) ) {
			out.error= "#out.statusCode# unknown error";
		} else if ( out.statusCode == "" ) {
			out.error= "unknown error, no status code";
		} else if ( out.response == "Connection Timeout" || out.response == "Connection Failure" ) {
			out.error= out.response;
		} else if ( out.statusCode == "200" ) {
			//  out.success 
			out.success= true;
		}
		//  parse response 
		if ( out.success ) {
			try {
				if ( left( out.response, 1 ) == "{" ) {
					out.response= deserializeJSON( out.response );
				} else {
					out.error= "Non-JSON Response: #out.response#";
				}
			} catch (any cfcatch) {
				out.error= "JSON Error: " & cfcatch.message;
			}
		}
		if ( len( out.error ) ) {
			out.success= false;
		}
		return out;
	}

}
