// Where a track's moving artwork comes from, in the user's order: the Canvas Spotify gives the track and
// Apple Music's animated album cover. Either can be switched off. The player and the lock screen walk the
// order (SGMotionClipFor); the album page's animated cover asks only whether Apple Music is on.
//
// A track whose metadata names no Canvas has it asked of Spotify's Canvas service, the way Spotify's own
// player is told of one, as the signed-in app (SGSpclientHeaders).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGSourcesPage.h"
#import "Shared/Lyrics/Lyrics.h"
#import "AnimatedArtwork.h"
#import "SGCustomArtwork.h"
#import "SGMotionClip.h"

static NSString *const kCanvas = @"canvas", *const kAppleMusic = @"applemusic";

static NSArray<SGSource *> *allSources(void) {
    return @[
        [SGSource sourceWithKey:kCanvas name:@"Spotify Canvas" detail:@"The track's own looping video"],
        [SGSource sourceWithKey:kAppleMusic name:@"Apple Music" detail:@"The album's animated cover"],
    ];
}

NSArray<NSString *> *SGMotionSourceOrder(void) {
    id stored = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyMotionSources];
    NSArray *keys = [stored isKindOfClass:NSArray.class] ? stored : @[kCanvas, kAppleMusic];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id key in keys) {
        if (([key isEqual:kCanvas] || [key isEqual:kAppleMusic]) && ![order containsObject:key]) [order addObject:key];
    }
    return order;
}

BOOL SGMotionAppleMusicOn(void) {
    return [SGMotionSourceOrder() containsObject:kAppleMusic];
}

NSURL *SGMotionCanvasIn(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    id type = metadata[@"canvas.type"], address = metadata[@"canvas.url"];
    BOOL video = [type isKindOfClass:NSString.class] && [type rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound;
    return video && [address isKindOfClass:NSString.class] ? [NSURL URLWithString:address] : nil;
}

// What the service answered for each track this launch, its Canvas's address or NSNull for none, and the
// askers waiting on an answer in flight. A request that failed is not kept, so the next walk asks again.
static NSMutableDictionary<NSString *, id> *sg_answers;
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_asking;

static void canvasFromService(NSString *uri, void (^done)(NSURL *canvas)) {
    // Songs only: a local file, an episode or an ad has no Canvas to ask for.
    id answer = [uri hasPrefix:@"spotify:track:"] ? sg_answers[uri] : NSNull.null;
    if (answer) {
        done([answer isKindOfClass:NSString.class] ? [NSURL URLWithString:answer] : nil);
        return;
    }
    if (sg_asking[uri]) {
        [sg_asking[uri] addObject:[done copy]];
        return;
    }
    // Asked only with the headers already seen: the walk does not wait for Spotify's first request.
    __block NSDictionary<NSString *, NSString *> *headers = nil;
    __block BOOL waited = NO;
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *seen) {
        if (!waited) headers = seen;
    });
    waited = YES;
    NSData *body = SGMotionCanvasAsk(uri);
    if (!headers || !body) {
        done(nil);
        return;
    }
    if (!sg_answers) sg_answers = [NSMutableDictionary dictionary];
    if (!sg_asking) sg_asking = [NSMutableDictionary dictionary];
    sg_asking[uri] = [NSMutableArray arrayWithObject:[done copy]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://spclient.wg.spotify.com/canvaz-cache/v0/canvases"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:name];
    }];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    request.allowsConstrainedNetworkAccess = SGFlag(SGKeyMotionLowData, NO);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *reply, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *address = status == 200 ? SGMotionCanvasInReply(reply) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            static NSUInteger logged;
            if (logged++ < 5 || status != 200) SGLog(@"motion: Canvas service for %@: %ld, %@", uri, (long)status, address ? @"a video" : @"none");
            if (status == 200) sg_answers[uri] = address ?: (id)NSNull.null;
            NSArray *waiting = sg_asking[uri];
            [sg_asking removeObjectForKey:uri];
            for (void (^waiter)(NSURL *) in waiting) waiter(address ? [NSURL URLWithString:address] : nil);
        });
    }] resume];
}

void SGMotionClipFor(NSString *uri, NSURL *canvas, NSString *artist, NSString *album, SGMotionShape shape, CGFloat pixels,
                     void (^done)(NSURL *file, NSString *source)) {
    // The person's own artwork for the song comes before every source (SGCustomArtwork.h).
    NSURL *own = SGCustomArtworkFor(uri);
    if (own) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(own, @"custom"); });
        return;
    }
    NSArray<NSString *> *order = SGMotionSourceOrder();
    // The walk holds itself until it ends, when it lets go.
    __block void (^ask)(NSUInteger) = nil;
    void (^finish)(NSURL *, NSString *) = ^(NSURL *file, NSString *source) {
        ask = nil;
        done(file, source);
    };
    void (^step)(NSUInteger) = ^(NSUInteger index) {
        if (index >= order.count) {
            finish(nil, nil);
            return;
        }
        NSString *source = order[index];
        void (^next)(NSURL *) = ^(NSURL *file) {
            if (file) finish(file, source);
            else ask(index + 1);
        };
        if ([source isEqualToString:kCanvas]) {
            if (canvas) SGMotionFile(canvas, next);
            else canvasFromService(uri, ^(NSURL *found) {
                if (found) SGMotionFile(found, next);
                else next(nil);
            });
        } else {
            SGMotionAlbumCover(artist, album, shape, pixels, next);
        }
    };
    ask = step;
    step(0);
}

SGModRow *SGMotionSourcesRow(void) {
    SGModRow *row = SGPageRow(@"Artwork sources", ^UIViewController *{
        return SGSourcesPageMake(@"Artwork sources", @"Asked top to bottom until one has a clip for the track. Apple Music is "
                                                     @"asked for the album by its name; it never sees your account.",
                                 allSources(), ^NSArray<NSString *> * { return SGMotionSourceOrder(); },
                                 ^(NSArray<NSString *> *keys) { [NSUserDefaults.standardUserDefaults setObject:keys forKey:SGKeyMotionSources]; });
    });
    row.value = ^NSString * {
        NSArray<NSString *> *order = SGMotionSourceOrder();
        if (!order.count) return @"Off";
        NSString *first = [order.firstObject isEqualToString:kCanvas] ? @"Canvas" : @"Apple Music";
        return order.count == 1 ? first : [NSString stringWithFormat:@"%@ +%lu", first, (unsigned long)order.count - 1];
    };
    return SGWithSymbol(row, @"square.stack.3d.down.right");
}
