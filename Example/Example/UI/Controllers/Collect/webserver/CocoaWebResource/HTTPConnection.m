#import "AsyncSocket.h"
#import "HTTPServer.h"
#import "HTTPConnection.h"
#import "HTTPResponse.h"
#import "HTTPAuthenticationRequest.h"
#import "DDNumber.h"
#import "DDRange.h"
#import "DDData.h"
#import "RegexKitLite.h"

#import "FileResource.h"


// Define chunk size used to read files from disk
#define READ_CHUNKSIZE     (1024 * 512)

// Define the various timeouts (in seconds) for various parts of the HTTP process
#define READ_TIMEOUT          -1
#define WRITE_HEAD_TIMEOUT    30
#define WRITE_BODY_TIMEOUT    -1
#define WRITE_ERROR_TIMEOUT   30
#define NONCE_TIMEOUT        300

// Define the various limits
// LIMIT_MAX_HEADER_LINE_LENGTH: Max length (in bytes) of any single line in a header (including \r\n)
// LIMIT_MAX_HEADER_LINES      : Max number of lines in a single header (including first GET line)
#define LIMIT_MAX_HEADER_LINE_LENGTH  8190
#define LIMIT_MAX_HEADER_LINES         100

#define BODY_BUFFER_SIZE 8190

// Define the various tags we'll use to differentiate what it is we're currently doing
#define HTTP_REQUEST                       15
#define HTTP_REQUEST_BODY				   16
#define HTTP_REQUEST_BODY_MULTIPART_HEAD   17
#define HTTP_REQUEST_BODY_MULTIPART		   18
#define HTTP_PARTIAL_RESPONSE              24
#define HTTP_PARTIAL_RESPONSE_HEADER       25
#define HTTP_PARTIAL_RESPONSE_BODY         26
#define HTTP_PARTIAL_RANGE_RESPONSE_BODY   28
#define HTTP_PARTIAL_RANGES_RESPONSE_BODY  29
#define HTTP_RESPONSE                      30
#define HTTP_FINAL_RESPONSE                45

// A quick note about the tags:
// 
// The HTTP_RESPONSE and HTTP_FINAL_RESPONSE are designated tags signalling that the response is completely sent.
// That is, in the onSocket:didWriteDataWithTag: method, if the tag is HTTP_RESPONSE or HTTP_FINAL_RESPONSE,
// it is assumed that the response is now completely sent.
// 
// If you are sending multiple data segments in a custom response, make sure that only the last segment has
// the HTTP_RESPONSE tag. For all other segments prior to the last segment use HTTP_PARTIAL_RESPONSE, or some other
// tag of your own invention.

@interface HTTPConnection (PrivateAPI)
- (CFHTTPMessageRef)prepareUniRangeResponse:(UInt64)contentLength;
- (CFHTTPMessageRef)prepareMultiRangeResponse:(UInt64)contentLength;

- (void)handleMultipartHeader:(NSData*)body;
- (void)handleMultipartBody:(NSData*)body;
@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation HTTPConnection

@synthesize params;
@synthesize request;

static NSMutableArray *recentNonces;

/**
 * This method is automatically called (courtesy of Cocoa) before the first instantiation of this class.
 * We use it to initialize any static variables.
**/
+ (void)initialize
{
	static BOOL initialized = NO;
	if(!initialized)
	{
		// Initialize class variables
		recentNonces = [[NSMutableArray alloc] initWithCapacity:5];
		
		initialized = YES;
	}
}

/**
 * This method is designed to be called by a scheduled timer, and will remove a nonce from the recent nonce list.
 * The nonce to remove should be set as the timer's userInfo.
**/
+ (void)removeRecentNonce:(NSTimer *)aTimer
{
	[recentNonces removeObject:[aTimer userInfo]];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Init, Dealloc:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Sole Constructor.
 * Associates this new HTTP connection with the given AsyncSocket.
 * This HTTP connection object will become the socket's delegate and take over responsibility for the socket.
**/
- (id)initWithAsyncSocket:(AsyncSocket *)newSocket forServer:(HTTPServer *)myServer
{
	if(self = [super init])
	{
		// Take over ownership of the socket
		asyncSocket = [newSocket retain];
		[asyncSocket setDelegate:self];
		
		// Store reference to server
		// Note that we do not retain the server. Parents retain their children, children do not retain their parents.
		server = myServer;
		
		// Initialize lastNC (last nonce count)
		// These must increment for each request from the client
		lastNC = 0;
		
		// Create a new HTTP message
		// Note the second parameter is YES, because it will be used for HTTP requests from the client
		request = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, YES);
		
		numHeaderLines = 0;
		
		bodyReadCount = 0;
		bodyLength = 0;
		remainBody = nil;
		tmpUploadFileHandle = nil;
		requestBoundry = nil;
		userAgent = nil;

		resource = nil;
		params = [[NSMutableDictionary alloc] init];
		
		// And now that we own the socket, and we have our CFHTTPMessage object (for requests) ready,
		// we can start reading the HTTP requests...
		[asyncSocket readDataToData:[AsyncSocket CRLFData]
						withTimeout:READ_TIMEOUT
						  maxLength:LIMIT_MAX_HEADER_LINE_LENGTH
								tag:HTTP_REQUEST];
	}
	return self;
}

/**
 * Standard Deconstructor.
**/
- (void)dealloc
{
	[asyncSocket setDelegate:nil];
	[asyncSocket disconnect];
	[asyncSocket release];
	
	if(request) CFRelease(request);
	if(requestBoundry) [requestBoundry release];
	if(userAgent) [userAgent release];
	
	[nonce release];
	
	[httpResponse release];
	
	[resource release];
	[params release];
	
	[ranges release];
	[ranges_headers release];
	[ranges_boundry release];
	
	[super dealloc];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Connection Control:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Returns whether or not the server is configured to be a secure server.
 * In other words, all connections to this server are immediately secured, thus only secure connections are allowed.
 * This is the equivalent of having an https server, where it is assumed that all connections must be secure.
 * If this is the case, then unsecure connections will not be allowed on this server, and a separate unsecure server
 * would need to be run on a separate port in order to support unsecure connections.
 * 
 * Note: In order to support secure connections, the sslIdentityAndCertificates method must be implemented.
**/
- (BOOL)isSecureServer
{
	// Override me to create an https server...
	
	return NO;
}

/**
 * This method is expected to returns an array appropriate for use in kCFStreamSSLCertificates SSL Settings.
 * It should be an array of SecCertificateRefs except for the first element in the array, which is a SecIdentityRef.
**/
- (NSArray *)sslIdentityAndCertificates
{
	// Override me to provide the proper required SSL identity.
	// You can configure the identity for the entire server, or based on the current request
	
	return nil;
}

/**
 * Returns whether or not the requested resource is password protected.
 * In this generic implementation, nothing is password protected.
**/
- (BOOL)isPasswordProtected:(NSString *)path
{
	// Override me to provide password protection...
	// You can configure it for the entire server, or based on the current request
	
	return NO;
}

/**
 * Returns whether or not the authentication challenge should use digest access authentication.
 * The alternative is basic authentication.
 * 
 * If at all possible, digest access authentication should be used because it's more secure.
 * Basic authentication sends passwords in the clear and should be avoided unless using SSL/TLS.
**/
- (BOOL)useDigestAccessAuthentication
{
	// Override me to use customize the authentication scheme
	// Make sure you understand the security consequences of using basic authentication
	
	return YES;
}

/**
 * Returns the authentication realm.
 * In this generic implmentation, a default realm is used for the entire server.
**/
- (NSString *)realm
{
	// Override me to provide a custom realm...
	// You can configure it for the entire server, or based on the current request
	
	return @"defaultRealm@host.com";
}

/**
 * Returns the password for the given username.
 * This password will be used to generate the response hash to validate against the given response hash.
**/
- (NSString *)passwordForUser:(NSString *)username
{
	// Override me to provide proper password authentication
	// You can configure a password for the entire server, or custom passwords for users and/or resources
	
	// Note: A password of nil, or a zero-length password is considered the equivalent of no password
	
	return nil;
}

/**
 * Generates and returns an authentication nonce.
 * A nonce is a  server-specified string uniquely generated for each 401 response.
 * The default implementation uses a single nonce for each session.
**/
- (NSString *)generateNonce
{
	// We use the Core Foundation UUID class to generate a nonce value for us
	// UUIDs (Universally Unique Identifiers) are 128-bit values guaranteed to be unique.
	CFUUIDRef theUUID = CFUUIDCreate(NULL);
    NSString *newNonce = [(NSString *)CFUUIDCreateString(NULL, theUUID) autorelease];
    CFRelease(theUUID);
	
	// We have to remember that the HTTP protocol is stateless
	// Even though with version 1.1 persistent connections are the norm, they are not guaranteed
	// Thus if we generate a nonce for this connection,
	// it should be honored for other connections in the near future
	// 
	// In fact, this is absolutely necessary in order to support QuickTime
	// When QuickTime makes it's initial connection, it will be unauthorized, and will receive a nonce
	// It then disconnects, and creates a new connection with the nonce, and proper authentication
	// If we don't honor the nonce for the second connection, QuickTime will repeat the process and never connect
	
	[recentNonces addObject:newNonce];
	
	[NSTimer scheduledTimerWithTimeInterval:NONCE_TIMEOUT
									 target:[HTTPConnection class]
								   selector:@selector(removeRecentNonce:)
								   userInfo:newNonce
									repeats:NO];
	return newNonce;
}

/**
 * Returns whether or not the user is properly authenticated.
 * Authentication is done using Digest Access Authentication accoring to RFC 2617.
**/
- (BOOL)isAuthenticated
{
	// Extract the authentication information from the Authorization header
	HTTPAuthenticationRequest *auth = [[[HTTPAuthenticationRequest alloc] initWithRequest:request] autorelease];
	
	if([self useDigestAccessAuthentication])
	{
		// Digest Access Authentication
		
		if(![auth isDigest])
		{
			// User didn't send proper digest access authentication credentials
			return NO;
		}
		
		if([auth username] == nil)
		{
			// The client didn't provide a username
			// Most likely they didn't provide any authentication at all
			return NO;
		}
		
		NSString *password = [self passwordForUser:[auth username]];
		if((password == nil) || ([password length] == 0))
		{
			// There is no password set, or the password is an empty string
			// We can consider this the equivalent of not using password protection
			return YES;
		}
		
		NSString *method = [(NSString *)CFHTTPMessageCopyRequestMethod(request) autorelease];
		
		NSURL *absoluteUrl = [(NSURL *)CFHTTPMessageCopyRequestURL(request) autorelease];
		NSString *url = [(NSURL *)absoluteUrl relativeString];
		
		if(![url isEqualToString:[auth uri]])
		{
			// Requested URL and Authorization URI do not match
			// This could be a replay attack
			// IE - attacker provides same authentication information, but requests a different resource
			return NO;
		}
		
		// The nonce the client provided will most commonly be stored in our local (cached) nonce variable
		if(![nonce isEqualToString:[auth nonce]])
		{
			// The given nonce may be from another connection
			// We need to search our list of recent nonce strings that have been recently distributed
			if([recentNonces containsObject:[auth nonce]])
			{
				// Store nonce in local (cached) nonce variable to prevent array searches in the future
				[nonce release];
				nonce = [[auth nonce] copy];
				
				// The client has switched to using a different nonce value
				// This may happen if the client tries to get a file in a directory with different credentials.
				// The previous credentials wouldn't work, and the client would receive a 401 error
				// along with a new nonce value. The client then uses this new nonce value and requests the file again.
				// Whatever the case may be, we need to reset lastNC, since that variable is on a per nonce basis.
				lastNC = 0;
			}
			else
			{
				// We have no knowledge of ever distributing such a nonce
				// This could be a replay attack from a previous connection in the past
				return NO;
			}
		}
		
		if([[auth nc] intValue] <= lastNC)
		{
			// The nc value (nonce count) hasn't been incremented since the last request
			// This could be a replay attack
			return NO;
		}
		lastNC = [[auth nc] intValue];
		
		NSString *HA1str = [NSString stringWithFormat:@"%@:%@:%@", [auth username], [auth realm], password];
		NSString *HA2str = [NSString stringWithFormat:@"%@:%@", method, [auth uri]];
		
		NSString *HA1 = [[[HA1str dataUsingEncoding:NSUTF8StringEncoding] md5Digest] hexStringValue];
		
		NSString *HA2 = [[[HA2str dataUsingEncoding:NSUTF8StringEncoding] md5Digest] hexStringValue];
		
		NSString *responseStr = [NSString stringWithFormat:@"%@:%@:%@:%@:%@:%@",
								 HA1, [auth nonce], [auth nc], [auth cnonce], [auth qop], HA2];
		
		NSString *response = [[[responseStr dataUsingEncoding:NSUTF8StringEncoding] md5Digest] hexStringValue];
		
		return [response isEqualToString:[auth response]];
	}
	else
	{
		// Basic Authentication
		
		if(![auth isBasic])
		{
			// User didn't send proper base authentication credentials
			return NO;
		}
		
		// Decode the base 64 encoded credentials
		NSString *base64Credentials = [auth base64Credentials];
		
		NSData *temp = [[base64Credentials dataUsingEncoding:NSUTF8StringEncoding] base64Decoded];
		
		NSString *credentials = [[[NSString alloc] initWithData:temp encoding:NSUTF8StringEncoding] autorelease];
		
		// The credentials should be of the form "username:password"
		// The username is not allowed to contain a colon
		
		NSRange colonRange = [credentials rangeOfString:@":"];
		
		if(colonRange.length == 0)
		{
			// Malformed credentials
			return NO;
		}
		
		NSString *credUsername = [credentials substringToIndex:colonRange.location];
		NSString *credPassword = [credentials substringFromIndex:(colonRange.location + colonRange.length)];
		
		NSString *password = [self passwordForUser:credUsername];
		if((password == nil) || ([password length] == 0))
		{
			// There is no password set, or the password is an empty string
			// We can consider this the equivalent of not using password protection
			return YES;
		}
		
		return [password isEqualToString:credPassword];
	}
}

/**
 * Adds a digest access authentication challenge to the given response.
**/
- (void)addDigestAuthChallenge:(CFHTTPMessageRef)response
{
	NSString *authFormat = @"Digest realm=\"%@\", qop=\"auth\", nonce=\"%@\"";
	NSString *authInfo = [NSString stringWithFormat:authFormat, [self realm], [self generateNonce]];
	
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("WWW-Authenticate"), (CFStringRef)authInfo);
}

/**
 * Adds a basic authentication challenge to the given response.
**/
- (void)addBasicAuthChallenge:(CFHTTPMessageRef)response
{
	NSString *authFormat = @"Basic realm=\"%@\"";
	NSString *authInfo = [NSString stringWithFormat:authFormat, [self realm]];
	
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("WWW-Authenticate"), (CFStringRef)authInfo);
}

/**
 * Attempts to parse the given range header into a series of non-overlapping ranges.
 * If successfull, the variables 'ranges' and 'rangeIndex' will be updated, and YES will be returned.
 * Otherwise, NO is returned, and the range request should be ignored.
 **/
- (BOOL)parseRangeRequest:(NSString *)rangeHeader withContentLength:(UInt64)contentLength
{
	// Examples of byte-ranges-specifier values (assuming an entity-body of length 10000):
	// 
	// - The first 500 bytes (byte offsets 0-499, inclusive):  bytes=0-499
	// 
	// - The second 500 bytes (byte offsets 500-999, inclusive): bytes=500-999
	// 
	// - The final 500 bytes (byte offsets 9500-9999, inclusive): bytes=-500
	// 
	// - Or bytes=9500-
	// 
	// - The first and last bytes only (bytes 0 and 9999):  bytes=0-0,-1
	// 
	// - Several legal but not canonical specifications of the second 500 bytes (byte offsets 500-999, inclusive):
	// bytes=500-600,601-999
	// bytes=500-700,601-999
	// 
	
	NSRange eqsignRange = [rangeHeader rangeOfString:@"="];
	
	if(eqsignRange.location == NSNotFound) return NO;
	
	NSUInteger tIndex = eqsignRange.location;
	NSUInteger fIndex = eqsignRange.location + eqsignRange.length;
	
	NSString *rangeType  = [[[rangeHeader substringToIndex:tIndex] mutableCopy] autorelease];
	NSString *rangeValue = [[[rangeHeader substringFromIndex:fIndex] mutableCopy] autorelease];
	
	CFStringTrimWhitespace((CFMutableStringRef)rangeType);
	CFStringTrimWhitespace((CFMutableStringRef)rangeValue);
	
	if([rangeType caseInsensitiveCompare:@"bytes"] != NSOrderedSame) return NO;
	
	NSArray *rangeComponents = [rangeValue componentsSeparatedByString:@","];
	
	if([rangeComponents count] == 0) return NO;
	
	[ranges release];
	ranges = [[NSMutableArray alloc] initWithCapacity:[rangeComponents count]];
	
	rangeIndex = 0;
	
	// Note: We store all range values in the form of NSRange structs, wrapped in NSValue objects.
	// Since NSRange consists of NSUInteger values, the range is limited to 4 gigs on 32-bit architectures (ppc, i386)
	
	NSUInteger i;
	for(i = 0; i < [rangeComponents count]; i++)
	{
		NSString *rangeComponent = [rangeComponents objectAtIndex:i];
		
		NSRange dashRange = [rangeComponent rangeOfString:@"-"];
		
		if(dashRange.location == NSNotFound)
		{
			// We're dealing with an individual byte number
			
			UInt64 byteIndex;
			if(![NSNumber parseString:rangeComponent intoUInt64:&byteIndex]) return NO;
			
			[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(byteIndex, 1)]];
		}
		else
		{
			// We're dealing with a range of bytes
			
			tIndex = dashRange.location;
			fIndex = dashRange.location + dashRange.length;
			
			NSString *r1str = [rangeComponent substringToIndex:tIndex];
			NSString *r2str = [rangeComponent substringFromIndex:fIndex];
			
			UInt64 r1, r2;
			
			BOOL hasR1 = [NSNumber parseString:r1str intoUInt64:&r1];
			BOOL hasR2 = [NSNumber parseString:r2str intoUInt64:&r2];
			
			if(!hasR1)
			{
				// We're dealing with a "-[#]" range
				// 
				// r2 is the number of ending bytes to include in the range
				
				if(!hasR2) return NO;
				if(r2 > contentLength) return NO;
				
				UInt64 startIndex = contentLength - r2;
				
				[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(startIndex, r2)]];
			}
			else if(!hasR2)
			{
				// We're dealing with a "[#]-" range
				// 
				// r1 is the starting index of the range, which goes all the way to the end
				
				if(!hasR1) return NO;
				if(r1 >= contentLength) return NO;
				
				[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(r1, contentLength - r1)]];
			}
			else
			{
				// We're dealing with a normal "[#]-[#]" range
				// 
				// Note: The range is inclusive. So 0-1 has a length of 2 bytes.
				
				if(!hasR1) return NO;
				if(!hasR2) return NO;
				if(r1 > r2) return NO;
				
				[ranges addObject:[NSValue valueWithDDRange:DDMakeRange(r1, r2 - r1 + 1)]];
			}
		}
	}
	
	if([ranges count] == 0) return NO;
	
	for(i = 0; i < [ranges count] - 1; i++)
	{
		DDRange range1 = [[ranges objectAtIndex:i] ddrangeValue];
		
		NSUInteger j;
		for(j = i+1; j < [ranges count]; j++)
		{
			DDRange range2 = [[ranges objectAtIndex:j] ddrangeValue];
			
			DDRange iRange = DDIntersectionRange(range1, range2);
			
			if(iRange.length != 0)
			{
				return NO;
			}
		}
	}
	
	return YES;
}

/**
 * Gets the current date and time, formatted properly (according to RFC) for insertion into an HTTP header.
**/
- (NSString *)dateAsString:(NSDate *)date
{
	// Example: Sun, 06 Nov 1994 08:49:37 GMT
	
	NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
	[df setFormatterBehavior:NSDateFormatterBehavior10_4];
	[df setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]];
	[df setDateFormat:@"EEE, dd MMM y hh:mm:ss 'GMT'"];
	
	// For some reason, using zzz in the format string produces GMT+00:00
	
	return [df stringFromDate:date];
}

/**
 * This method is called after a full HTTP request has been received.
 * The current request is in the CFHTTPMessage request variable.
**/
- (void)replyToHTTPRequest
{
	// Check the HTTP version - if it's anything but HTTP version 1.1, we don't support it
	NSString *version = [(NSString *)CFHTTPMessageCopyVersion(request) autorelease];
	if(!version || ![version isEqualToString:(NSString *)kCFHTTPVersion1_1])
	{
		[self handleVersionNotSupported: version];
		return;
	}
	
	//Check Resources
	if ([FileResource canHandle:request])
	{
		resource = [[FileResource alloc] initWithConnection:self];
		resource.delegate = server.fileResourceDelegate;
		[resource handleRequest];
		return;
	}
	
	// Check HTTP method
	NSString *method = [(NSString *)CFHTTPMessageCopyRequestMethod(request) autorelease];
    if(![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"])
	{
		[self handleUnknownMethod:method];
        return;
    }
	
	// Extract requested URI
	NSURL *uri = [(NSURL *)CFHTTPMessageCopyRequestURL(request) autorelease];
	
	// Check Authentication (if needed)
	// If not properly authenticated for resource, issue Unauthorized response
	if([self isPasswordProtected:[uri relativeString]] && ![self isAuthenticated])
	{
		[self handleAuthenticationFailed];
		return;
	}
	
	[self handleResponse:(NSObject<HTTPResponse> *)[self httpResponseForURI:[uri relativeString]] method:method ];
}

- (void)handleResponse:(NSObject<HTTPResponse> *)rsp method:(NSString*)method
{
	// Respond properly to HTTP 'GET' and 'HEAD' commands
	httpResponse = [rsp retain];
	
	UInt64 contentLength = [httpResponse contentLength];
	
	if(contentLength == 0)
	{
		[self handleResourceNotFound];
		
		[httpResponse release];
		httpResponse = nil;
		
		return;
    }
	
	// Check for specific range request
	NSString *rangeHeader = [(NSString *)CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")) autorelease];
	
	BOOL isRangeRequest = NO;
	
	if(rangeHeader)
	{
		if([self parseRangeRequest:rangeHeader withContentLength:contentLength])
		{
			isRangeRequest = YES;
		}
	}
	
	CFHTTPMessageRef response;
	
	if(!isRangeRequest)
	{
		// Status Code 200 - OK
		response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1);
		
		NSString *contentLengthStr = [NSString stringWithFormat:@"%qu", contentLength];
		CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (CFStringRef)contentLengthStr);
	}
	else
	{
		if([ranges count] == 1)
		{
			response = [self prepareUniRangeResponse:contentLength];
		}
		else
		{
			response = [self prepareMultiRangeResponse:contentLength];
		}
	}
    
	// If they issue a 'HEAD' command, we don't have to include the file
	// If they issue a 'GET' command, we need to include the file
	if([method isEqual:@"HEAD"])
	{
		NSData *responseData = [self preprocessResponse:response];
		[asyncSocket writeData:responseData withTimeout:WRITE_HEAD_TIMEOUT tag:HTTP_RESPONSE];
	}
	else
	{
		// Write the header response
		NSData *responseData = [self preprocessResponse:response];
		[asyncSocket writeData:responseData withTimeout:WRITE_HEAD_TIMEOUT tag:HTTP_PARTIAL_RESPONSE_HEADER];
		
		// Now we need to send the body of the response
		if(!isRangeRequest)
		{
			// Regular request
			NSData *data = [httpResponse readDataOfLength:READ_CHUNKSIZE];
			
			[asyncSocket writeData:data withTimeout:WRITE_BODY_TIMEOUT tag:HTTP_PARTIAL_RESPONSE_BODY];
		}
		else
		{
			// Client specified a byte range in request
			
			if([ranges count] == 1)
			{
				// Client is requesting a single range
				DDRange range = [[ranges objectAtIndex:0] ddrangeValue];
				
				[httpResponse setOffset:range.location];
				
				unsigned int bytesToRead = range.length < READ_CHUNKSIZE ? range.length : READ_CHUNKSIZE;
				
				NSData *data = [httpResponse readDataOfLength:bytesToRead];
				
				[asyncSocket writeData:data withTimeout:WRITE_BODY_TIMEOUT tag:HTTP_PARTIAL_RANGE_RESPONSE_BODY];
			}
			else
			{
				// Client is requesting multiple ranges
				// We have to send each range using multipart/byteranges
				
				// Write range header
				NSData *rangeHeader = [ranges_headers objectAtIndex:0];
				[asyncSocket writeData:rangeHeader withTimeout:WRITE_HEAD_TIMEOUT tag:HTTP_PARTIAL_RESPONSE_HEADER];
				
				// Start writing range body
				DDRange range = [[ranges objectAtIndex:0] ddrangeValue];
				
				[httpResponse setOffset:range.location];
				
				unsigned int bytesToRead = range.length < READ_CHUNKSIZE ? range.length : READ_CHUNKSIZE;
				
				NSData *data = [httpResponse readDataOfLength:bytesToRead];
				
				[asyncSocket writeData:data withTimeout:WRITE_BODY_TIMEOUT tag:HTTP_PARTIAL_RANGES_RESPONSE_BODY];
			}
		}
	}
	
	CFRelease(response);
}

/**
 * Prepares a single-range response.
**/
- (CFHTTPMessageRef)prepareUniRangeResponse:(UInt64)contentLength
{
	// Status Code 206 - Partial Content
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 206, NULL, kCFHTTPVersion1_1);
	
	DDRange range = [[ranges objectAtIndex:0] ddrangeValue];
	
	NSString *contentLengthStr = [NSString stringWithFormat:@"%qu", range.length];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (CFStringRef)contentLengthStr);
	
	NSString *rangeStr = [NSString stringWithFormat:@"%qu-%qu", range.location, DDMaxRange(range) - 1];
	NSString *contentRangeStr = [NSString stringWithFormat:@"bytes %@/%qu", rangeStr, contentLength];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Range"), (CFStringRef)contentRangeStr);
	
	return response;
}

/**
 * Prepares a multi-range response.
**/
- (CFHTTPMessageRef)prepareMultiRangeResponse:(UInt64)contentLength
{
	// Status Code 206 - Partial Content
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 206, NULL, kCFHTTPVersion1_1);
	
	// We have to send each range using multipart/byteranges
	// So each byterange has to be prefix'd and suffix'd with the boundry
	// Example:
	// 
	// HTTP/1.1 206 Partial Content
	// Content-Length: 220
	// Content-Type: multipart/byteranges; boundary=4554d24e986f76dd6
	// 
	// 
	// --4554d24e986f76dd6
	// Content-range: bytes 0-25/4025
	// 
	// [...]
	// --4554d24e986f76dd6
	// Content-range: bytes 3975-4024/4025
	// 
	// [...]
	// --4554d24e986f76dd6--
	
	ranges_headers = [[NSMutableArray alloc] initWithCapacity:[ranges count]];
	
	CFUUIDRef theUUID = CFUUIDCreate(NULL);
	ranges_boundry = (NSString *)CFUUIDCreateString(NULL, theUUID);
	CFRelease(theUUID);
	
	NSString *startingBoundryStr = [NSString stringWithFormat:@"\r\n--%@\r\n", ranges_boundry];
	NSString *endingBoundryStr = [NSString stringWithFormat:@"\r\n--%@--\r\n", ranges_boundry];
	
	UInt64 actualContentLength = 0;
	
	unsigned i;
	for(i = 0; i < [ranges count]; i++)
	{
		DDRange range = [[ranges objectAtIndex:i] ddrangeValue];
		
		NSString *rangeStr = [NSString stringWithFormat:@"%qu-%qu", range.location, DDMaxRange(range) - 1];
		NSString *contentRangeVal = [NSString stringWithFormat:@"bytes %@/%qu", rangeStr, contentLength];
		NSString *contentRangeStr = [NSString stringWithFormat:@"Content-Range: %@\r\n\r\n", contentRangeVal];
		
		NSString *fullHeader = [startingBoundryStr stringByAppendingString:contentRangeStr];
		NSData *fullHeaderData = [fullHeader dataUsingEncoding:NSUTF8StringEncoding];
		
		[ranges_headers addObject:fullHeaderData];
		
		actualContentLength += [fullHeaderData length];
		actualContentLength += range.length;
	}
	
	NSData *endingBoundryData = [endingBoundryStr dataUsingEncoding:NSUTF8StringEncoding];
	
	actualContentLength += [endingBoundryData length];
	
	NSString *contentLengthStr = [NSString stringWithFormat:@"%qu", actualContentLength];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (CFStringRef)contentLengthStr);
	
	NSString *contentTypeStr = [NSString stringWithFormat:@"multipart/byteranges; boundary=%@", ranges_boundry];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), (CFStringRef)contentTypeStr);
	
	return response;
}

/**
 * Converts relative URI path into full file-system path.
**/
- (NSString *)filePathForURI:(NSString *)path
{
	// Override me to perform custom path mapping.
	// For example you may want to use a default file other than index.html, or perhaps support multiple types.
	
	// If there is no configured documentRoot, then it makes no sense to try to return anything
	if(![server documentRoot]) return nil;
	
	// Convert path to a relative path.
	// This essentially means trimming beginning '/' characters.
	// Beware of a bug in the Cocoa framework:
	// 
	// [NSURL URLWithString:@"/foo" relativeToURL:baseURL]       == @"/baseURL/foo"
	// [NSURL URLWithString:@"/foo%20bar" relativeToURL:baseURL] == @"/foo bar"
	// [NSURL URLWithString:@"/foo" relativeToURL:baseURL]       == @"/foo"
	
	NSString *relativePath = path;
	
	while([relativePath hasPrefix:@"/"] && [relativePath length] > 1)
	{
		relativePath = [relativePath substringFromIndex:1];
	}
	
	NSString *fullPath;
	
	if([relativePath hasSuffix:@"/"])
	{
		NSString *completedRelativePath = [relativePath stringByAppendingString:@"index.html"];
		fullPath = [NSString stringWithFormat:@"%@/%@", [server documentRoot], completedRelativePath];
	}
	else
	{
		fullPath = [NSString stringWithFormat:@"%@/%@", [server documentRoot], relativePath];
	}
	
	// Watch out for sneaky requests with ".." in the path
	// For example, the following request: "../Documents/TopSecret.doc"
	if (![[fullPath stringByStandardizingPath] hasPrefix:[server documentRoot]]) return nil;
	
	return [fullPath stringByStandardizingPath];
}

/**
 * This method is called to get a response for a request.
 * You may return any object that adopts the HTTPResponse protocol.
 * The HTTPServer comes with two such classes: HTTPFileResponse and HTTPDataResponse.
 * HTTPFileResponse is a wrapper for an NSFileHandle object, and is the preferred way to send a file response.
 * HTTPDataResopnse is a wrapper for an NSData object, and may be used to send a custom response.
**/
- (NSObject<HTTPResponse> *)httpResponseForURI:(NSString *)path
{
	// Override me to provide custom responses.
	
	NSString *filePath = [self filePathForURI:path];
	
	if([[NSFileManager defaultManager] fileExistsAtPath:filePath])
	{
		return [[[HTTPFileResponse alloc] initWithFilePath:filePath] autorelease];
	}
    else
    {
    	path = [path stringByReplacingPercentEscapesUsingEncoding:NSASCIIStringEncoding]; // Replace %20 with spaces for example
        
        NSString *folder = [path isEqualToString:@"/"] ? [server documentRoot] : [NSString stringWithFormat: @"%@%@", [server documentRoot], path];
        if ([self isBrowseable:folder])
        {
//            currentRoot = [[NSString alloc] initWithString:[NSString stringWithFormat: @"%@%@", [[server documentRoot] path], path]];
            
            NSData *browseData = [[self createBrowseableIndex:folder] dataUsingEncoding:NSUTF8StringEncoding];
            return [[[HTTPDataResponse alloc] initWithData:browseData] autorelease];
        }

    }
	
	return nil;
    
 
}
- (BOOL)isBrowseable:(NSString *)path
{
	
	NSDictionary *fileDict = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
	
	if ([[fileDict objectForKey:NSFileType] isEqualToString: @"NSFileTypeDirectory"]){
		return YES;
	}
    
	
    // Override me to provide custom configuration...
    // You can configure it for the entire server, or based on the current request
    
    return NO;
}

/**
 * This method creates a html browseable page.
 * Customize to fit your needs
 **/
- (NSString *) createBrowseableIndex:(NSString *)path
{
    NSArray *array = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
    
    NSMutableString *outdata = [NSMutableString new];
    [outdata appendString:@"<!DOCTYPE html>\n"];
    [outdata appendString:@"<html>\n<head> <meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"/>\n"];
    [outdata appendString:@"<title>openFileBrowser</title>\n"];
    [outdata appendString:@"<style>\n\
     body { \n\
	 background-color:#ffffff; \n\
	 background-image: url(data:image/png;base64,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);\n\
	 font-family:Tahoma,Arial,Helvetica,sans-serif; \n\
	 font-size:18x;  \n\
	 margin: 0px;  \n\
	 height: 100%; \n\
     }\n \
     div.container \n\
     {\n\
     background-color: #ffffff;\n\
     position: absolute; \n\
     width: 798px;\n\
     left: 50%;\n\
     top: 120px; \n\
     bottom: 0px; \n\
     margin-left: -400px;\n\
     border-left: 1px #a9a9a9 solid;\n\
     border-right: 1px #a9a9a9 solid;\n\
     }\n\
     div.header \n\
     {\n\
	 background-color: #ffffff;\n\
	 background-image: url(data:image/png;base64,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);\n\
	 position: absolute ; \n\
	 width: 800px;\n\
	 left: 50%;\n\
	 margin-left: -400px;\n\
	 height: 120px; \n\
     }\n\
     \n\
     a\n\
     {\n\
	 color: red;\n\
	 text-decoration: none; \n\
     }\n\
     \n\
     a:hover\n\
     {\n\
	 text-decoration: underline;\n\
     }\n\
     </style>"];
	
    [outdata appendString:@"</head>\n<body>"];
	[outdata appendString:@"<div class='header' id='header'> \n &nbsp;"];
	
	[outdata appendString:@"</div>\n"];
    
	[outdata appendString:@"<div class='container' id='container'>"];
    
	
	[outdata appendFormat:@"<table border='0'width='100%%' cellspacing='0' style='margin:0px;'>\n"];
	[outdata appendFormat:@"<tr style='height: 30px; background-color: #CBCABE;'>\n"];
	[outdata appendFormat:@"<td width='60%%'><b>&nbsp;File name</b></td><td width='15%%'><b>File size</b></td><td width='25%%'><b>Last modified</b></td></tr>\n"];
	
	[outdata appendFormat:@"<tr><td colspan='3'>&nbsp;&nbsp;<a href=\"..\"><b>&larr; Parent directory</b></a><br><br></td>"];
    
	
	
    for (NSString *fname in array)
    {
		NSString *optional = [[NSString alloc] initWithString:@""];
		
        NSDictionary *fileDict = [[NSFileManager defaultManager] attributesOfItemAtPath:[path stringByAppendingPathComponent:fname] error:NULL];
        NSString *modDate = [NSDateFormatter localizedStringFromDate:[fileDict objectForKey:NSFileModificationDate]
                                                           dateStyle:NSDateFormatterMediumStyle
                                                           timeStyle:NSDateFormatterShortStyle];
        
        if ([[fileDict objectForKey:NSFileType] isEqualToString: @"NSFileTypeDirectory"]){
			fname = [fname stringByAppendingString:@"/"];
			optional = @"&nbsp;&gt;&nbsp;<i>";
		}
		
		if (![fname hasPrefix:@"."]) // Don't append .DS_Store
		{
			[outdata appendFormat:@"<tr><td>&nbsp;%@<a href=\"%@\">%@</a></td><td>%8.1f Kb</td><td>%@</td></tr>\n", optional, fname, fname, [[fileDict objectForKey:NSFileSize] floatValue] / 1024, modDate];
		}
		
		[optional release];
    }
    [outdata appendString:@"</table>\n"];
	[outdata appendString:@"<br>\n"];
    
    if ([self supportsPOST:path withSize:0])
    {
        [outdata appendString:@"<form action=\"\" method=\"post\" enctype=\"multipart/form-data\" name=\"form1\" id=\"form1\">"];
        [outdata appendString:@"<label>&nbsp;Select file(s) to upload, use ctrl/shift to multi select (HTML5 enabled browser required, IE9 not yet!)<br>\n<br>\n"];
        [outdata appendString:@"<input type=\"file\" name=\"file[]\" multiple />"];
        [outdata appendString:@"</label>"];
        [outdata appendString:@"<label>"];
        [outdata appendString:@"<input type=\"submit\" name=\"button\" id=\"button\" value=\"Submit\" />"];
        [outdata appendString:@"</label>"];
        [outdata appendString:@"</form>"];
    }
	
    [outdata appendString:@"</div>\n"];
    [outdata appendString:@"</body></html>"];
    
    return [outdata autorelease];
}


/**
 * Called if the HTML version is other than what is supported
**/
- (void)handleVersionNotSupported:(NSString *)version
{
	// Override me for custom error handling of unspupported http version responses
	// If you simply want to add a few extra header fields, see the preprocessErrorResponse: method.
	// You can also use preprocessErrorResponse: to add an optional HTML body.
	
	NSLog(@"HTTP Server: Error 505 - Version Not Supported: %@", version);
	
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 505, NULL, (CFStringRef)version);
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), CFSTR("0"));
    
	NSData *responseData = [self preprocessErrorResponse:response];
	[asyncSocket writeData:responseData withTimeout:WRITE_ERROR_TIMEOUT tag:HTTP_RESPONSE];
	
	CFRelease(response);
}

/**
 * Called if the authentication information was required and absent, or if authentication failed.
**/
- (void)handleAuthenticationFailed
{
	// Override me for custom handling of authentication challenges
	// If you simply want to add a few extra header fields, see the preprocessErrorResponse: method.
	// You can also use preprocessErrorResponse: to add an optional HTML body.
	
	NSLog(@"HTTP Server: Error 401 - Unauthorized");
		
	// Status Code 401 - Unauthorized
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 401, NULL, kCFHTTPVersion1_1);
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), CFSTR("0"));
	
	if([self useDigestAccessAuthentication])
	{
		[self addDigestAuthChallenge:response];
	}
	else
	{
		[self addBasicAuthChallenge:response];
	}
	
	NSData *responseData = [self preprocessErrorResponse:response];
	[asyncSocket writeData:responseData withTimeout:WRITE_ERROR_TIMEOUT tag:HTTP_RESPONSE];
	
	CFRelease(response);
}

/**
 * Called if we receive some sort of malformed HTTP request.
 * The data parameter is the invalid HTTP header line, including CRLF, as read from AsyncSocket.
**/
- (void)handleInvalidRequest:(NSData *)data
{
	// Override me for custom error handling of invalid HTTP requests
	// If you simply want to add a few extra header fields, see the preprocessErrorResponse: method.
	// You can also use preprocessErrorResponse: to add an optional HTML body.
	
	NSLog(@"HTTP Server: Error 400 - Bad Request");
	
	// Status Code 400 - Bad Request
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 400, NULL, kCFHTTPVersion1_1);
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), CFSTR("0"));
	
	NSData *responseData = [self preprocessErrorResponse:response];
	[asyncSocket writeData:responseData withTimeout:WRITE_ERROR_TIMEOUT tag:HTTP_FINAL_RESPONSE];
	
	CFRelease(response);
	
	// Close connection as soon as the error message is sent
	[asyncSocket disconnectAfterWriting];
}

/**
 * Called if we receive a HTTP request with a method other than GET or HEAD.
**/
- (void)handleUnknownMethod:(NSString *)method
{
	// Override me to add support for methods other than GET and HEAD
	// If you simply want to add a few extra header fields, see the preprocessErrorResponse: method.
	// You can also use preprocessErrorResponse: to add an optional HTML body.
	
	NSLog(@"HTTP Server: Error 405 - Method Not Allowed: %@", method);
	
	// Status code 405 - Method Not Allowed
    CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 405, NULL, kCFHTTPVersion1_1);
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), CFSTR("0"));
	
	NSData *responseData = [self preprocessErrorResponse:response];
	[asyncSocket writeData:responseData withTimeout:WRITE_ERROR_TIMEOUT tag:HTTP_RESPONSE];
    
	CFRelease(response);
}

- (void)handleResourceNotFound
{
	// Override me for custom error handling of 404 not found responses
	// If you simply want to add a few extra header fields, see the preprocessErrorResponse: method.
	// You can also use preprocessErrorResponse: to add an optional HTML body.
	
	NSLog(@"HTTP Server: Error 404 - Not Found");
	
	// Status Code 404 - Not Found
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 404, NULL, kCFHTTPVersion1_1);
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), CFSTR("0"));
	
	NSData *responseData = [self preprocessErrorResponse:response];
	[asyncSocket writeData:responseData withTimeout:WRITE_ERROR_TIMEOUT tag:HTTP_RESPONSE];
	
	CFRelease(response);
}

- (void)handleServiceUnavailable
{
	// Override me for custom error handling of 503 not found responses
	// If you simply want to add a few extra header fields, see the preprocessErrorResponse: method.
	// You can also use preprocessErrorResponse: to add an optional HTML body.
	
	NSLog(@"HTTP Server: Error 503 - Not Found");
	
	// Status Code 503 - Not Found
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 503, NULL, kCFHTTPVersion1_1);
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), CFSTR("0"));
	
	NSData *responseData = [self preprocessErrorResponse:response];
	[asyncSocket writeData:responseData withTimeout:WRITE_ERROR_TIMEOUT tag:HTTP_RESPONSE];
	
	CFRelease(response);
}

/* handle redirection */
- (void)redirectoTo:(NSString*)path
{
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 302, NULL, kCFHTTPVersion1_1);
	NSString *content = [NSString stringWithFormat:@"<html><body>You are being <a href=\"%@\">redirected</a>.</body></html>", path];
	NSString *length = [NSString stringWithFormat:@"%d", [content length]];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (CFStringRef)length);
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), CFSTR("text/html; charset=utf-8"));
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Location"), (CFStringRef)path);	
	NSData *responseData = (NSData *)CFHTTPMessageCopySerializedMessage(response);
	[asyncSocket writeData:responseData withTimeout:WRITE_ERROR_TIMEOUT tag:HTTP_FINAL_RESPONSE];
	
	CFRelease(response);
	[responseData autorelease];
	
	// Close connection as soon as the error message is sent
	[asyncSocket disconnectAfterWriting];	
}

/* send text */
- (void)sendString:(NSString*)text mimeType:(NSString*)mimeType
{
	if (nil == mimeType)
		mimeType = @"text/plain";
	
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1);
	NSString *content = text;
	NSString *length = [NSString stringWithFormat:@"%d", [[content dataUsingEncoding:NSUTF8StringEncoding] length]];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (CFStringRef)length);
	NSString* contentType = [NSString stringWithFormat:@"%@; charset=utf-8", mimeType];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), (CFStringRef)contentType );
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Cache-Control"), CFSTR("private, max-age=0, must-revalidate") );

	NSData *responseData = [self preprocessResponse:response];
	[asyncSocket writeData:responseData withTimeout:WRITE_HEAD_TIMEOUT tag:HTTP_FINAL_RESPONSE];
	
	[asyncSocket writeData:[content dataUsingEncoding:NSUTF8StringEncoding] withTimeout:WRITE_BODY_TIMEOUT tag:HTTP_FINAL_RESPONSE];
	
	CFRelease(response);
	
	// Close connection as soon as the error message is sent
	[asyncSocket disconnectAfterWriting];
}
/* handle request body */
- (void)handleHTTPRequestBody:(NSData*)data tag:(long)tag
{
	if (bodyLength == 0)
		return;
	
	long newTag = HTTP_REQUEST_BODY;
	
	if (nil == data)
	{
		// init body info
		NSDictionary* header = (NSDictionary*)CFHTTPMessageCopyAllHeaderFields(request);
		NSString* contentType = [header objectForKey:@"Content-Type"];
		if (nil != contentType)
		{
			// checkout boundary
			NSError *error;
			NSRange searchRange = NSMakeRange(0, [contentType length]);
			NSRange matchedRange = NSMakeRange(NSNotFound, 0);
			matchedRange = [contentType rangeOfRegex:@"\\Amultipart/form-data.*boundary=\"?([^\";,]+)\"?"
											 options: RKLCaseless
											 inRange:searchRange
											 capture:1
											   error:&error];
			if (matchedRange.location != NSNotFound)
			{
				requestBoundry = [NSString stringWithFormat:@"%@%@", @"--", [contentType substringWithRange:matchedRange]];
				[requestBoundry retain];
				newTag = HTTP_REQUEST_BODY_MULTIPART_HEAD;
			}
		}
		[header release];
	}
	else
	{
		switch (tag) {
			case HTTP_REQUEST_BODY:
				[self parsePostBody:data];
				break;
			case HTTP_REQUEST_BODY_MULTIPART_HEAD:
				[self handleMultipartHeader:data];
				newTag = HTTP_REQUEST_BODY_MULTIPART;
				break;
			case HTTP_REQUEST_BODY_MULTIPART:
				[self handleMultipartBody:data];
				newTag = HTTP_REQUEST_BODY_MULTIPART;
			default:
				break;
		}
		bodyReadCount += [data length];
	}
	
	int readLength = BODY_BUFFER_SIZE;
	int remain = bodyLength - bodyReadCount;
	if (readLength > remain)
		readLength = remain;

	NSString* progress = [NSString stringWithFormat:@"%f", 1.0 - remain * 1.0 / bodyLength];
	[[NSNotificationCenter defaultCenter] postNotificationName:HTTPUploadingProgressNotification object:progress];

	if (readLength > 0)
		[asyncSocket readDataToLength:readLength withTimeout:READ_TIMEOUT tag:newTag];
	else
		[self replyToHTTPRequest];
}

/* parse post body for parameters */
- (void)parsePostBody:(NSData*)data
{
	NSString *body = [[NSString alloc] initWithBytes:[data bytes] length:[data length] encoding:NSUTF8StringEncoding];
	NSArray* paramstr = [body componentsSeparatedByString:@"&"];
	
	for (NSString* pair in paramstr)
	{
		NSArray* keyvalue = [pair componentsSeparatedByString:@"="];
		if ([keyvalue count] == 2)
			[params setObject:[keyvalue objectAtIndex:1] forKey:[[keyvalue objectAtIndex:0] lowercaseString]];
		else
			NSLog(@"misformat parameters in POST:%@", pair);
	}
	[body release];
}

/* parsing head info for multipart body */
- (void)handleMultipartHeader:(NSData*)body
{
	NSLog(@"parsing multipart header");
	NSString * EOL = @"\015\012";
	// check boundary
	NSRange range = NSMakeRange(0, [requestBoundry length] + [EOL length]);
	NSString *bHead = [NSString stringWithUTF8String:(const char *)[[body subdataWithRange:range] bytes]];
	if (![bHead isEqualToString:[NSString stringWithFormat:@"%@%@", requestBoundry, EOL]])
	{
		NSLog(@"bad content body");
		return;
	}
	
	// read head to get file name
	range = NSMakeRange([requestBoundry length] + [EOL length], [body length]- [requestBoundry length] - [EOL length]);
	const char* bytes = [[body subdataWithRange:range] bytes];
	NSLog(@"bytes %x", bytes);
	int length = range.length;
	const char* deol = "\015\012\015\012";
	const char *headEnd = strstr(bytes, deol);
	NSString *bodyHeader = [[NSString alloc] initWithBytes:bytes length:(headEnd - bytes) encoding:NSUTF8StringEncoding];
	NSRange matchedRange = NSMakeRange(NSNotFound, 0);
	NSRange searchRange = NSMakeRange(0, [bodyHeader length]);
	NSError *error;
	matchedRange = [bodyHeader rangeOfRegex:@"Content-Disposition:.* filename=(?:\"((?:\\\\.|[^\\\"])*)\"|([^;]*))"
									options: RKLCaseless
									inRange:searchRange
									capture:1
									  error:&error];
	
	NSString *filename = [bodyHeader substringWithRange:matchedRange];
	if ([userAgent isMatchedByRegex:@"MSIE .* Windows "]
		&& [filename isMatchedByRegex:@"\\A([a-zA-Z]:\\\\|\\\\\\\\)"])
	{
		NSArray *pathSegs = [filename componentsSeparatedByString:@"\\"];
		filename = [pathSegs lastObject];
	}
	
	matchedRange = [bodyHeader rangeOfRegex:@"Content-Disposition:.* name=\"?([^\\\";]*)\"?"
									options: RKLCaseless
									inRange:searchRange
									capture:1
									  error:&error];
	NSString *key = [bodyHeader substringWithRange:matchedRange];
	[params setObject:filename forKey:key];
	[[NSNotificationCenter defaultCenter] postNotificationName:HTTPUploadingStartNotification object:filename];
	
	CFUUIDRef theUUID = CFUUIDCreate(NULL);
	CFStringRef uuidString = CFUUIDCreateString(NULL, theUUID);
	NSString *tmpName = [NSString stringWithFormat:@"%@/%@", NSTemporaryDirectory(), (NSString *)uuidString];
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm createFileAtPath:tmpName contents:[NSData data] attributes:nil];
	tmpUploadFileHandle = [NSFileHandle fileHandleForWritingAtPath:tmpName];
	[tmpUploadFileHandle retain];
	CFRelease(theUUID);
	CFRelease(uuidString);
	[params setObject:tmpName forKey:@"tmpfilename"];
	[bodyHeader release];
	
	length = length - (headEnd - bytes + strlen(deol));
	bytes = headEnd + strlen(deol);
	NSData *fileContent = [NSData dataWithBytesNoCopy:(void*)bytes length:length freeWhenDone:NO];

	[self handleMultipartBody:fileContent];
}

- (void)handleMultipartBody:(NSData*)body
{
	if (nil == tmpUploadFileHandle)
		return;
	
	static NSString* deol = @"\015\012";
	NSString *terminator = [NSString stringWithFormat:@"%@%@", deol, requestBoundry];
	NSMutableData *data = [[NSMutableData alloc] init];
	if (remainBody)
		[data appendData:remainBody];
	[data appendData:body];
	
	const char* bytes = [data bytes];
	const char* cterminator = [terminator UTF8String];
	const char* candidate = memchr(bytes, '\015', [data length]);
	const char* contentEnd = NULL;
	int taillen = [data length] + bytes - candidate;
	while (candidate && taillen >= [terminator length]) {
		contentEnd = strnstr(candidate, cterminator, [terminator length]);
		if (contentEnd)
			break;
		candidate = memchr(candidate+1, '\015', taillen - 1);
		taillen = [data length] + bytes - candidate;
	}
	if (NULL != contentEnd)
	{
		NSRange range = NSMakeRange(0, contentEnd - bytes);
		NSData* content = [data subdataWithRange:range];
		[tmpUploadFileHandle writeData:content];
		[tmpUploadFileHandle release];
		tmpUploadFileHandle = nil;
	}
	else
	{
		NSRange range = NSMakeRange(0, [data length] - [terminator length]);
		NSData* content = [data subdataWithRange:range];
		range = NSMakeRange([data length] - [terminator length], [terminator length]);
		if (remainBody)
			[remainBody release];
		remainBody = [data subdataWithRange:range];
		[remainBody retain];
		
		[tmpUploadFileHandle writeData:content];
	}
	[data release];
}

/**
 * This method is called immediately prior to sending the response headers.
 * This method adds standard header fields, and then converts the response to an NSData object.
**/
- (NSData *)preprocessResponse:(CFHTTPMessageRef)response
{
	// Override me to customize the response headers
	// You'll likely want to add your own custom headers, and then return [super preprocessResponse:response]
	
	NSString *now = [self dateAsString:[NSDate date]];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Date"), (CFStringRef)now);
	
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Accept-Ranges"), CFSTR("bytes"));
	
	NSData *result = (NSData *)CFHTTPMessageCopySerializedMessage(response);
	return [result autorelease];
}

/**
 * This method is called immediately prior to sending the response headers (for an error).
 * This method adds standard header fields, and then converts the response to an NSData object.
**/
- (NSData *)preprocessErrorResponse:(CFHTTPMessageRef)response;
{
	// Override me to customize the error response headers
	// You'll likely want to add your own custom headers, and then return [super preprocessErrorResponse:response]
	// 
	// Notes:
	// You can use CFHTTPMessageGetResponseStatusCode(response) to get the type of error.
	// You can use CFHTTPMessageSetBody() to add an optional HTML body.
	// If you add a body, don't forget to update the Content-Length.
	// 
	// if(CFHTTPMessageGetResponseStatusCode(response) == 404)
	// {
	//     NSString *msg = @"<html><body>Error 404 - Not Found</body></html>";
	//     NSData *msgData = [msg dataUsingEncoding:NSUTF8StringEncoding];
	//     
	//     CFHTTPMessageSetBody(response, (CFDataRef)msgData);
	//     
	//     NSString *contentLengthStr = [NSString stringWithFormat:@"%u", (unsigned)[msgData length]];
	//     CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), (CFStringRef)contentLengthStr);
	// }
	
	NSString *now = [self dateAsString:[NSDate date]];
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Date"), (CFStringRef)now);
	
	CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Accept-Ranges"), CFSTR("bytes"));
	
	NSData *result = (NSData *)CFHTTPMessageCopySerializedMessage(response);
	return [result autorelease];
}

- (void)die
{
	// Post notification of dead connection
	// This will allow our server to release us from its array of connections
	[[NSNotificationCenter defaultCenter] postNotificationName:HTTPConnectionDidDieNotification object:self];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark AsyncSocket Delegate Methods:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method is called immediately prior to opening up the stream.
 * This is the time to manually configure the stream if necessary.
**/
- (BOOL)onSocketWillConnect:(AsyncSocket *)sock
{
	if([self isSecureServer])
	{
		NSArray *certificates = [self sslIdentityAndCertificates];
		
		if([certificates count] > 0)
		{
			NSLog(@"Securing connection...");
			
			// All connections are assumed to be secure. Only secure connections are allowed on this server.
			NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithCapacity:3];
			
			// Configure this connection as the server
			CFDictionaryAddValue((CFMutableDictionaryRef)settings,
								 kCFStreamSSLIsServer, kCFBooleanTrue);
			
			CFDictionaryAddValue((CFMutableDictionaryRef)settings,
								 kCFStreamSSLCertificates, (CFArrayRef)certificates);
			
			// Configure this connection to use the highest possible SSL level
			CFDictionaryAddValue((CFMutableDictionaryRef)settings,
								 kCFStreamSSLLevel, kCFStreamSocketSecurityLevelNegotiatedSSL);
			
			CFReadStreamSetProperty([asyncSocket getCFReadStream],
									kCFStreamPropertySSLSettings, (CFDictionaryRef)settings);
			CFWriteStreamSetProperty([asyncSocket getCFWriteStream],
									 kCFStreamPropertySSLSettings, (CFDictionaryRef)settings);
		}
	}
	return YES;
}

/**
 * This method is called after the socket has successfully read data from the stream.
 * Remember that this method will only be called after the socket reaches a CRLF, or after it's read the proper length.
**/
- (void)onSocket:(AsyncSocket *)sock didReadData:(NSData*)data withTag:(long)tag
{
	if (!CFHTTPMessageIsHeaderComplete(request))
	{
		// Append the header line to the http message
		BOOL result = CFHTTPMessageAppendBytes(request, [data bytes], [data length]);
		if(!result)
		{
			// We have a received a malformed request
			[self handleInvalidRequest:data];
		}
		else if(!CFHTTPMessageIsHeaderComplete(request))
		{
			// We don't have a complete header yet
			// That is, we haven't yet received a CRLF on a line by itself, indicating the end of the header
			if(++numHeaderLines > LIMIT_MAX_HEADER_LINES)
			{
				// Reached the maximum amount of header lines in a single HTTP request
				// This could be an attempted DOS attack
				[asyncSocket disconnect];
			}
			else
			{
				[asyncSocket readDataToData:[AsyncSocket CRLFData]
								withTimeout:READ_TIMEOUT
								  maxLength:LIMIT_MAX_HEADER_LINE_LENGTH
										tag:HTTP_REQUEST];
			}
		}
		else
		{
			NSDictionary* header = (NSDictionary*)CFHTTPMessageCopyAllHeaderFields(request);
			NSString* lenstr = (NSString*)[header objectForKey:@"Content-Length"];
			if (nil == userAgent)
			{
				userAgent = [header objectForKey:@"User-Agent"];
				[userAgent retain];
			}			
			
			bodyLength = 0;
			if (nil != lenstr)
			{
				bodyLength = [lenstr intValue];
				bodyReadCount = 0;
			}
			if (bodyLength == 0)
				[self replyToHTTPRequest];
			else
				[self handleHTTPRequestBody:nil tag:tag];
			[header release];
		}
	}
	else // handle request body
		[self handleHTTPRequestBody:data tag:tag];
}

/**
 * This method is called after the socket has successfully written data to the stream.
 * Remember that this method will be called after a complete response to a request has been written.
**/
- (void)onSocket:(AsyncSocket *)sock didWriteDataWithTag:(long)tag
{
	BOOL doneSendingResponse = NO;
	
	if(tag == HTTP_PARTIAL_RESPONSE_BODY)
	{
		// We only wrote a part of the http response - there may be more.
		NSData *data = [httpResponse readDataOfLength:READ_CHUNKSIZE];
		
		if([data length] > 0)
		{
			[asyncSocket writeData:data withTimeout:WRITE_BODY_TIMEOUT tag:tag];
		}
		else
		{
			doneSendingResponse = YES;
		}
	}
	else if(tag == HTTP_PARTIAL_RANGE_RESPONSE_BODY)
	{
		// We only wrote a part of the range - there may be more.
		DDRange range = [[ranges objectAtIndex:0] ddrangeValue];
		
		UInt64 offset = [httpResponse offset];
		UInt64 bytesRead = offset - range.location;
		UInt64 bytesLeft = range.length - bytesRead;
		
		if(bytesLeft > 0)
		{
			unsigned int bytesToRead = bytesLeft < READ_CHUNKSIZE ? bytesLeft : READ_CHUNKSIZE;
			
			NSData *data = [httpResponse readDataOfLength:bytesToRead];
			
			[asyncSocket writeData:data withTimeout:WRITE_BODY_TIMEOUT tag:tag];
		}
		else
		{
			doneSendingResponse = YES;
		}
	}
	else if(tag == HTTP_PARTIAL_RANGES_RESPONSE_BODY)
	{
		// We only wrote part of the range - there may be more.
		// Plus, there may be more ranges.
		DDRange range = [[ranges objectAtIndex:rangeIndex] ddrangeValue];
		
		UInt64 offset = [httpResponse offset];
		UInt64 bytesRead = offset - range.location;
		UInt64 bytesLeft = range.length - bytesRead;
		
		if(bytesLeft > 0)
		{
			unsigned int bytesToRead = bytesLeft < READ_CHUNKSIZE ? bytesLeft : READ_CHUNKSIZE;
			
			NSData *data = [httpResponse readDataOfLength:bytesToRead];
			
			[asyncSocket writeData:data withTimeout:WRITE_BODY_TIMEOUT tag:tag];
		}
		else
		{
			if(++rangeIndex < [ranges count])
			{
				// Write range header
				NSData *rangeHeader = [ranges_headers objectAtIndex:rangeIndex];
				[asyncSocket writeData:rangeHeader withTimeout:WRITE_HEAD_TIMEOUT tag:HTTP_PARTIAL_RESPONSE_HEADER];
				
				// Start writing range body
				range = [[ranges objectAtIndex:rangeIndex] ddrangeValue];
				
				[httpResponse setOffset:range.location];
				
				unsigned int bytesToRead = range.length < READ_CHUNKSIZE ? range.length : READ_CHUNKSIZE;
				
				NSData *data = [httpResponse readDataOfLength:bytesToRead];
				
				[asyncSocket writeData:data withTimeout:WRITE_BODY_TIMEOUT tag:tag];
			}
			else
			{
				// We're not done yet - we still have to send the closing boundry tag
				NSString *endingBoundryStr = [NSString stringWithFormat:@"\r\n--%@--\r\n", ranges_boundry];
				NSData *endingBoundryData = [endingBoundryStr dataUsingEncoding:NSUTF8StringEncoding];
				
				[asyncSocket writeData:endingBoundryData withTimeout:WRITE_HEAD_TIMEOUT tag:HTTP_RESPONSE];
			}
		}
	}
	else if(tag == HTTP_RESPONSE)
	{
		doneSendingResponse = YES;
	}
	
	if(doneSendingResponse)
	{
		// Release any resources we no longer need
		[httpResponse release];
		httpResponse = nil;
		
		[ranges release];
		[ranges_headers release];
		[ranges_boundry release];
		ranges = nil;
		ranges_headers = nil;
		ranges_boundry = nil;
		
		// Release the old request, and create a new one
		if(request) CFRelease(request);
		request = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, YES);
		
		numHeaderLines = 0;
		
		// And start listening for more requests
		[asyncSocket readDataToData:[AsyncSocket CRLFData]
						withTimeout:READ_TIMEOUT
						  maxLength:LIMIT_MAX_HEADER_LINE_LENGTH
								tag:HTTP_REQUEST];
	}
}

/**
 * This message is sent:
 *  - if there is an connection, time out, or other i/o error.
 *  - if the remote socket cleanly disconnects.
 *  - before the local socket is disconnected.
**/
- (void)onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)err
{
	if(err)
	{
		//NSLog(@"HTTPConnection:willDisconnectWithError: %@", err);
	}
}

/**
 * Sent after the socket has been disconnected.
**/
- (void)onSocketDidDisconnect:(AsyncSocket *)sock
{
	[self die];
}

@end
