//
//  PBGitCommitController.m
//  GitX
//
//  Created by Pieter de Bie on 19-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "PBGitCommitController.h"
#import "NSFileHandleExt.h"
#import "PBChangedFile.h"
#import "PBWebChangesController.h"

@implementation PBGitCommitController

@synthesize files, status, busy, amend;

- (void)awakeFromNib
{
	self.files = [NSMutableArray array];
	[super awakeFromNib];
	[self refresh:self];

	[commitMessageView setTypingAttributes:[NSDictionary dictionaryWithObject:[NSFont fontWithName:@"Monaco" size:12.0] forKey:NSFontAttributeName]];
	
	[unstagedFilesController setFilterPredicate:[NSPredicate predicateWithFormat:@"hasUnstagedChanges == 1"]];
	[cachedFilesController setFilterPredicate:[NSPredicate predicateWithFormat:@"hasCachedChanges == 1"]];
	
	[unstagedFilesController setSortDescriptors:[NSArray arrayWithObjects:
		[[NSSortDescriptor alloc] initWithKey:@"status" ascending:false],
		[[NSSortDescriptor alloc] initWithKey:@"path" ascending:true], nil]];
	[cachedFilesController setSortDescriptors:[NSArray arrayWithObject:
		[[NSSortDescriptor alloc] initWithKey:@"path" ascending:true]]];
}
- (void) removeView
{
	[(PBWebChangesController *)webController closeView];
	[super finalize];
}

- (void) setAmend:(BOOL)newAmend
{
	if (newAmend == amend)
		return;
	amend = newAmend;

	if (amend && [[commitMessageView string] length] <= 3)
		commitMessageView.string = [repository outputForCommand:@"log -1 --pretty=format:%s%n%n%b HEAD"];

	[self refresh:self];
}

- (NSArray *) linesFromNotification:(NSNotification *)notification
{
	NSDictionary *userInfo = [notification userInfo];
	NSData *data = [userInfo valueForKey:NSFileHandleNotificationDataItem];
	if (!data)
		return NULL;
	
	NSString* string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (!string)
		return NULL;
	
	// Strip trailing newline
	if ([string hasSuffix:@"\n"])
		string = [string substringToIndex:[string length]-1];
	
	NSArray *lines = [string componentsSeparatedByString:@"\0"];
	return lines;
}

- (NSString *) parentTree
{
	NSString *parent = amend ? @"HEAD^" : @"HEAD";

	if (![repository parseReference:parent])
		// We don't have a head ref. Return the empty tree.
		return @"4b825dc642cb6eb9a060e54bf8d69288fbee4904";

	return parent;
}

- (void) refresh:(id) sender
{
	for (PBChangedFile *file in files)
		file.shouldBeDeleted = YES;

	self.status = @"Refreshing index…";
	if (![repository workingDirectory]) {
	//if ([[repository outputForCommand:@"rev-parse --is-inside-work-tree"] isEqualToString:@"false"]) {
		return;
	}

	self.busy++;

	[repository outputInWorkdirForArguments:[NSArray arrayWithObjects:@"update-index", @"-q", @"--unmerged", @"--ignore-missing", @"--refresh", nil]];
	self.busy--;

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter]; 
	[nc removeObserver:self]; 

	// Other files
	NSArray *arguments = [NSArray arrayWithObjects:@"ls-files", @"--others", @"--exclude-standard", @"-z", nil];
	NSFileHandle *handle = [repository handleInWorkDirForArguments:arguments];
	[nc addObserver:self selector:@selector(readOtherFiles:) name:NSFileHandleReadToEndOfFileCompletionNotification object:handle]; 
	self.busy++;
	[handle readToEndOfFileInBackgroundAndNotify];
	
	// Unstaged files
	handle = [repository handleInWorkDirForArguments:[NSArray arrayWithObjects:@"diff-files", @"-z", nil]];
	[nc addObserver:self selector:@selector(readUnstagedFiles:) name:NSFileHandleReadToEndOfFileCompletionNotification object:handle]; 
	self.busy++;
	[handle readToEndOfFileInBackgroundAndNotify];

	// Cached files
	handle = [repository handleInWorkDirForArguments:[NSArray arrayWithObjects:@"diff-index", @"--cached", @"-z", [self parentTree], nil]];
	[nc addObserver:self selector:@selector(readCachedFiles:) name:NSFileHandleReadToEndOfFileCompletionNotification object:handle]; 
	self.busy++;
	[handle readToEndOfFileInBackgroundAndNotify];
}

- (void) updateView
{
	[self refresh:nil];
}

- (void) doneProcessingIndex
{
	[self willChangeValueForKey:@"files"];
	if (!--self.busy) {
		self.status = @"Ready";
		NSArray *filesToBeDeleted = [files filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"shouldBeDeleted == 1"]];
		for (PBChangedFile *file in filesToBeDeleted) {
				NSLog(@"Deleting file: %@", [file path]);
				[files removeObject:file];
		}
	}
	[self didChangeValueForKey:@"files"];
}

- (void) readOtherFiles:(NSNotification *)notification;
{
	[unstagedFilesController setAutomaticallyRearrangesObjects:NO];
	NSArray *lines = [self linesFromNotification:notification];
	for (NSString *line in lines) {
		if ([line length] == 0)
			continue;

		BOOL added = NO;
		// Check if file is already in our index
		for (PBChangedFile *file in files) {
			if ([[file path] isEqualToString:line]) {
				file.shouldBeDeleted = NO;
				added = YES;
				file.status = NEW;
				file.hasCachedChanges = NO;
				file.hasUnstagedChanges = YES;
				break;
			}
		}

		if (added)
			continue;

		// File does not exist yet, so add it
		PBChangedFile *file =[[PBChangedFile alloc] initWithPath:line];
		file.status = NEW;
		file.hasCachedChanges = NO;
		file.hasUnstagedChanges = YES;
		[files addObject: file];
	}
	[unstagedFilesController setAutomaticallyRearrangesObjects:YES];
	[unstagedFilesController rearrangeObjects];
	[self doneProcessingIndex];
}

- (void) addFilesFromLines:(NSArray *)lines cached:(BOOL) cached
{
	NSArray *fileStatus;
	int even = 0;
	for (NSString *line in lines) {
		if (!even) {
			even = 1;
			fileStatus = [line componentsSeparatedByString:@" "];
			continue;
		}
		even = 0;

		NSString *mode = [[fileStatus objectAtIndex:0] substringFromIndex:1];
		NSString *sha = [fileStatus objectAtIndex:2];

		BOOL isNew = YES;
		// If the file is already added, we shouldn't add it again
		// but rather update it to incorporate our changes
		for (PBChangedFile *file in files) {
			if ([file.path isEqualToString:line]) {
				if (cached && file.hasCachedChanges) {			// if we're listing cached files
					file.shouldBeDeleted = NO;			// and the matching file in files had cached changes
					file.commitBlobSHA = sha;			// we don't delete it
					file.commitBlobMode = mode;
					isNew = NO;
					break;
				} else if ((!cached) && file.hasUnstagedChanges) {	// if we're listing unstaged files and the
					file.shouldBeDeleted = NO;			// matching file in files had unstaged changes
					isNew = NO;					// we don't delete it
					break;
				}
			}
		}

		if (!isNew)
			continue;

		PBChangedFile *file = [[PBChangedFile alloc] initWithPath:line];
		if ([[fileStatus objectAtIndex:4] isEqualToString:@"D"])
			file.status = DELETED;
		else if([[fileStatus objectAtIndex:0] isEqualToString:@":000000"])
			file.status = NEW;
		else
			file.status = MODIFIED;

		file.commitBlobSHA = sha;
		file.commitBlobMode = mode;

		file.hasCachedChanges = cached;
		file.hasUnstagedChanges = !cached;

		[files addObject: file];
	}

}

- (void) readUnstagedFiles:(NSNotification *)notification
{
	NSArray *lines = [self linesFromNotification:notification];
	[self addFilesFromLines:lines cached:NO];
	[self doneProcessingIndex];
}

- (void) readCachedFiles:(NSNotification *)notification
{
	NSArray *lines = [self linesFromNotification:notification];
	[self addFilesFromLines:lines cached:YES];
	[self doneProcessingIndex];
}

- (void) commitFailedBecause:(NSString *)reason
{
	self.busy--;
	self.status = [@"Commit failed: " stringByAppendingString:reason];
	[[NSAlert alertWithMessageText:@"Commit failed"
					 defaultButton:nil
				   alternateButton:nil
					   otherButton:nil
		 informativeTextWithFormat:reason] runModal];
	return;
}

- (IBAction) commit:(id) sender
{
	if ([[cachedFilesController arrangedObjects] count] == 0) {
		[[NSAlert alertWithMessageText:@"No changes to commit"
						 defaultButton:nil
					   alternateButton:nil
						   otherButton:nil
			 informativeTextWithFormat:@"You must first stage some changes before committing"] runModal];
		return;
	}		
	
	NSString *commitMessage = [commitMessageView string];
	if ([commitMessage length] < 3) {
		[[NSAlert alertWithMessageText:@"Commitmessage missing"
						 defaultButton:nil
					   alternateButton:nil
						   otherButton:nil
			 informativeTextWithFormat:@"Please enter a commit message before committing"] runModal];
		return;
	}

	[cachedFilesController setSelectionIndexes:[NSIndexSet indexSet]];
	[unstagedFilesController setSelectionIndexes:[NSIndexSet indexSet]];

	NSString *commitSubject;
	NSRange newLine = [commitMessage rangeOfString:@"\n"];
	if (newLine.location == NSNotFound)
		commitSubject = commitMessage;
	else
		commitSubject = [commitMessage substringToIndex:newLine.location];
	
	commitSubject = [@"commit: " stringByAppendingString:commitSubject];

	self.busy++;
	self.status = @"Creating tree..";
	NSString *tree = [repository outputForCommand:@"write-tree"];
	if ([tree length] != 40)
		return [self commitFailedBecause:@"Could not create a tree"];

	int ret;

	NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"commit-tree", tree, nil];
	NSString *parent = amend ? @"HEAD^" : @"HEAD";
	if ([repository parseReference:parent]) {
		[arguments addObject:@"-p"];
		[arguments addObject:parent];
	}

	NSString *commit = [repository outputForArguments:arguments
										  inputString:commitMessage
											 retValue: &ret];

	if (ret || [commit length] != 40)
		return [self commitFailedBecause:@"Could not create a commit object"];

	if (![repository executeHook:@"pre-commit" output:nil])
		return [self commitFailedBecause:@"Pre-commit hook failed"];

	[repository outputForArguments:[NSArray arrayWithObjects:@"update-ref", @"-m", commitSubject, @"HEAD", commit, nil]
						  retValue: &ret];
	if (ret)
		return [self commitFailedBecause:@"Could not update HEAD"];

	if (![repository executeHook:@"post-commit" output:nil])
		[(PBWebChangesController *)webController setStateMessage:[NSString stringWithFormat:@"Post-commit hook failed, however, successfully created commit %@", commit]];
	else
		[(PBWebChangesController *)webController setStateMessage:[NSString stringWithFormat:@"Successfully created commit %@", commit]];

	repository.hasChanged = YES;
	self.busy--;
	[commitMessageView setString:@""];
	amend = NO;
	[self refresh:self];
	self.amend = NO;
}

- (void) stageHunk:(NSString *)hunk reverse:(BOOL)reverse
{
	NSMutableArray *array = [NSMutableArray arrayWithObjects:@"apply", @"--cached", nil];
	if (reverse)
		[array addObject:@"--reverse"];

	int ret;
	NSString *error = [repository outputForArguments:array
										 inputString:hunk
											retValue: &ret];
	if (ret)
		NSLog(@"Error: %@", error);
	[self refresh:self]; // TODO: We should do this smarter by checking if the file diff is empty, which is faster.
}
@end
