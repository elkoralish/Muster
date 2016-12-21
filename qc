
import os
import sys
import grp
import pwd
import stat
import json
import bbgithub
from optparse import OptionParser
from subprocess import Popen, PIPE, call, check_call

# =-=-==-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# get options and arguments
use = '%s [--errors] [--quiet] [--help]' % sys.argv[0]
parser = OptionParser(usage = use)

parser.add_option("--errors",
                  dest="errors", action="store_true", default=False,
                  help="only display errors")

parser.add_option("--quiet",
                  dest="quiet", action="store_true", default=False,
                  help="display nothing")

parser.add_option("--debug",
                  dest="debug", action="store_true", default=False,
                  help="display nothing")

parser.add_option("--nodb",
                  dest="nodb", action="store_true", default=False,
                  help="skip db checks")

parser.add_option("--nonfs",
                  dest="nonfs", action="store_true", default=False,
                  help="skip nfs mount checks")

parser.add_option("--nolink",
                  dest="nolink", action="store_true", default=False,
                  help="skip symlink checks")

parser.add_option("--nodir",
                  dest="nodir", action="store_true", default=False,
                  help="skip directory checks")

parser.add_option("--nofile",
                  dest="nofile", action="store_true", default=False,
                  help="skip file checks")

parser.add_option("--nocron",
                  dest="nocron", action="store_true", default=False,
                  help="skip cron checks")

parser.add_option("--noproc",
                  dest="noproc", action="store_true", default=False,
                  help="skip process checks")

OPTIONS, ARGUMENTS = parser.parse_args()
COMMAND = ' '.join(ARGUMENTS) # not used, only options here

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# some initial setup and a few global vars
VERB = "normal"
if OPTIONS.debug:
     # retrofitting debug in here without refactoring code using 'VERB'
     OPTIONS.errors = False
     OPTIONS.quiet = False
else:
     if OPTIONS.errors: VERB = "errors"
     if OPTIONS.quiet:  VERB = "quiet"
RED = "\033[31m{0}\033[00m"
BRIGHTRED = "\033[01;31m{0}\033[00m"
GREEN = "\033[01;32m{0}\033[00m"
GRAY = "\033[01;30m{0}\033[00m"
YELLOW = "\033[01;33m{0}\033[00m"
LIGHTBLUE = "\033[01;36m{0}\033[00m"
REVERSERED = "\033[1;41m{0}\033[00m"
FAILURES = []
CONFIGERRORS = []

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# BBGitHub functions
def bbgh_connect():
     ''' connect to BBGitHub mantle repository bbgithub:deveng/mantle '''
     bbgh = bbgithub.get_ghe()
     mantle = bbgh.repository('deveng', 'mantle')
     return bbgh, mantle

def fetch_contents(mantle, filename):
     ''' read a mantle file from bbgithub '''
     data =  mantle.contents('etc/mantle.d/' + filename, 'master')
     contents = json.loads(data.decoded)
     if OPTIONS.debug: print('++ filename: {}'.format(filename))
     return contents

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# output display functions
def width():
     try:
          rows, columns = Popen(['stty', 'size'], stderr=PIPE, stdout=PIPE).communicate()[0].strip().split()
     except:
          columns = 80
     return int(columns)

def spacer(description, char=" "):
          return char * (width() - len(description) - 20)

def showresults(description, result):
     ''' description is text
         result is True|False for Ok|Fail error|na for !!|NA '''
     if not VERB == "normal" : return
     if type(result) == bool:
          if result:
               print("     %s %s   [%s] " % (description, spacer(description), GREEN.format("Ok")))
          else:
               print("     %s %s  <%s>" % (description, spacer(description, '.'), BRIGHTRED.format("Fail")))
     elif type(result) == str:
          if result.lower() == "error":
               print("     %s %s%s  -*%s*-" % (description, spacer(description, '<'), '<'*13, BRIGHTRED.format("!!")))
          elif result.lower() == "na":
               print("     %s %s   %s " % (description, spacer(description), GRAY.format("/NA/")))

def toodles(exitcode=0):
     if not len(CONFIGERRORS) == 0 and not VERB == "quiet":
          if exitcode == 0: exitcode = 1
          if VERB == "normal":
               print("\n Configuration Errors:       ")
               print(" ============================\n")
          if not VERB == "quiet":
               for line in CONFIGERRORS:
                    print(" %s %s" % (BRIGHTRED.format("*"), line))

     if not len(FAILURES) == 0:
          if exitcode == 0: exitcode = 1
          if VERB == "normal":
               print("\n Failure Report:             ")
               print(" ============================\n")
          if not VERB == "quiet":
               for line in FAILURES:
                    desc = line.split(',')[-1].strip()
                    if "(" in desc or "[" in desc or "/" in desc or line.split(',')[0] == "plain":
                         pass
                    else:
                         desc = desc + " (%s)" % line.split(',')[0].strip()
                    if "(" in desc: #highlight bracketed text RED
                         start = desc.split("(")[0] + "("
                         highlight = BRIGHTRED.format(desc.split("(")[1].split(")")[0])
                         end = ")" + desc.split(")")[1]
                         desc = start + highlight + end
                    if line.split(',')[-1].strip().endswith(')'): desc += ")"
                    print(" %s %s" % (BRIGHTRED.format("*"), desc))
     if VERB == 'normal': print
     exit(exitcode)

def pp(item):
     ''' pretty print. json printing debug display function '''
     if type(item) == dict: json.dump(item, sys.stdout, indent=4)
     elif type(item) == list:
          for i in item: print(i)
     else: print(item)
     print("")

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# get host information functions
def taglist():
     try:
          tags = [ line for line in open('/bb/bin/bbcpu.lst') if line.split()[0] == os.uname()[1] ][0].split()
     except:
          FAILURES.append("Unable to run '/bb/bin/bbhost localhost', cannot retrieve tags")
          toodles(1)
     if not tags:
          FAILURES.append("Unable to run '/bb/bin/bbhost localhost', cannot retrieve tags (rc=%s)" % rc)
          toodles(1)
     return tags

def pslist():
     return Popen(['ps', '-eoargs'], stdout=PIPE).communicate()[0].split('\n')[1:]

def glmdblist():
     command = '/bb/bin/glm'
     if checkfilename(command):
          glm = Popen([command, 'g'], stdout=PIPE)
          stdout, stderr = glm.communicate()#[0].split('\n')
          rc = glm.returncode
          if not rc == 0: return False, "problem running {}: {}: no shaRED memory".format(command, stdout)
          output = stdout.split('\n')
          return True, [l.split()[1] for l in output if len(l.strip()) > 0 and not l.strip().startswith('#')]
     return False, "/bb/bin/glm not present or zero length"

# =-=-=-=-=-=-=-==-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# utility functions
def sudo (runthis, user=None):
     ''' run command via sudo as user '''
     command = ['sudo']
     if type(runthis) is str: runthis = runthis.split()
     if user :
          user = "-u%s" % user
          command.append(user)
     command.extend(runthis)
     p = Popen(command, stdout=PIPE, stderr=PIPE)
     stdout, stderr = p.communicate()
     rc = p.returncode
     if not rc == 0: return False, "command error:" + stderr
     return True, stdout

def striplist(l):
     ''' strips whitespace from list members '''
     return [ i.strip() for i in l ]

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# json manipulation functions
def parse_mantle_json(mytags, data, default_data=None):
     '''
     This is the workhorse of parsing the mantle files.
     We dig through mantle json object, return parts relative to this host
     NOTE: this procedure will recurse itself several times if necessary
     any time a label or symv(@) is encounteRED
     '''
     output = {}
     if not default_data: default_data = {}
     # ------------------------------------------------------------------------
     # stuff we don't need for this -------------------------------------------
     ignorekeys = ['%name', '%schema', '%description', '%comment']
     # ------------------------------------------------------------------------
     # handle defaults entry if present ---------------------------------------
     if '%default' in data.keys():
          for key in data['%default']:
               if key in ignorekeys: continue
               default_data[key[1:]] = data['%default'][key]
          del data['%default']
     # ------------------------------------------------------------------------
     # data items present in this structure, load defaults if present ---------
     if default_data and [ x for x in data.keys() if x.startswith('%') ]:
          output = dict(default_data)
     # handle the rest of the keys in this structure --------------------------
     for key in data.keys():
          if key in ignorekeys: continue
          relevant = True
          # -------------------------------------------------------------------
          # '@' means symv, determine if relevant and recurse if so -----------
          if key.startswith('@'):
               if " " in key[1:]: symv = key[1:].split()
               else: symv = [key[1:]]
               if checktags(mytags, symv):
                    if OPTIONS.debug:
                         print("** symv({}) relevant? {}".format(key[1:].split(), relevant))
                    return_data = (parse_mantle_json(mytags, data[key], default_data))
                    if return_data: output.update(return_data)
          # -------------------------------------------------------------------
          # '%' means data, we need this, move to output key ------------------
          elif key.startswith('%'): output[key[1:]] = data[key]
          # -------------------------------------------------------------------
          # key is a check label, recurse and fill with output data -----------
          else:
               return_data = parse_mantle_json(mytags, data[key], default_data)
               if return_data: output['check:' + key] = return_data
     # ------------------------------------------------------------------------
     # should be (and probably is) a better way, but time is tight and this is
     # a quick (if dirty) way to determine the check type of check
     if 'filer_device' in output.keys(): output['type'] = 'nfs'                 # done
     elif 'dbname' in output.keys(): output['type'] = 'database'                # done
     elif 'target_path' in output.keys(): output['type'] = 'symlink'            # done
     elif 'file_path'  in output.keys(): output['type'] = 'file'                # done, not in mantle
     elif 'account_name' in output.keys(): output['type'] = 'account'           # not in mantle
     elif 'version_command' in output.keys(): output['type'] = 'vesrion'        # not in mantle
     elif 'kernel_version' in output.keys(): output['type'] = 'kernel'          # not in mantle
     elif 'patch_version' in output.keys(): output['type'] = 'patch'            # not in mantle
     elif 'fsfree_path' in output.keys(): output['type'] = 'fsfree'             # not in mantle
     elif 'inodes_path' in output.keys(): output['type'] = 'inodes'             # not in mantle
     elif 'fssize_path' in output.keys(): output['type'] = 'fssize'             # not in mantle
     elif 'cron_command' in output.keys(): output['type'] = 'cron'              # done
     elif 'at_user' in output.keys(): output['type'] = 'at'                     # not in mantle
     elif 'process_name' in output.keys(): output['type'] = 'process'           # done
     elif 'dir_path' in output.keys(): output['type'] = 'directory'             # done
     return output

def flatten(checks, level=0):
     output = {}
     level += 1
     #print("level %s" % level) # TODO debug
     for check in checks:
          level2 = [ c2 for c2 in checks[check].keys() if c2.startswith('check:')]
          if level2: output.update(flatten(checks[check], level))
          else: output[check] = checks[check]
     return output

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# common check functions
def checkmount(path):
     if os.path.exists:
          if os.path.islink(path): return False
          return os.path.ismount(path)
     else: return False

def checkuser(path, users):
     ''' checks user ownership of object against list of valid users '''
     info = os.stat(path)
     try: actual_user = pwd.getpwuid(info.st_uid)[0]
     except KeyError: actual_user = str(info.st_uid)
     for user in users:
          if user.strip() == actual_user: return True, user
     else: return False, actual_user

def checkgroup(path, groups):
     ''' checks group ownership of object against list of valid groups '''
     info = os.stat(path)
     try: actual_group = grp.getgrgid(info.st_gid)[0]
     except KeyError: actual_group = str(info.st_gid)
     for group in groups:
          if group.strip() == actual_group: return True, group
     else: return False, actual_group

def checkperms(path, perms):
     ''' checks group ownership of object against list of valid groups '''
     info = os.stat(path)
     actual_perms = oct(info.st_mode)[2:]
     if int(perms) == int(actual_perms): return True, perms
     else: return False, actual_perms

def checkfiler(path, filer, volume):
     ''' checks that the filer and volume of the fs mounted on path match '''
     info = Popen(['/opt/bb/bin/df', '-h', path], stdout=PIPE, stderr=PIPE)
     stdout, stderr = info.communicate()
     rc = info.returncode
     if rc == 0:
          info = stdout.split('\n')[1].split()[0].split(':')
          actual_filer = info[0]
          actual_volume = info[1]
          if actual_filer == filer and actual_volume == volume:
               return True, actual_filer, actual_volume
          else:
               return False, actual_filer, actual_volume
     else: return False, None, None

def checkproc(checkfor, processes):
     #print("\nchk: %s" % repr(checkfor)) # TODO debug
     for row in processes:
          #if 'sysmon' in row: print("row: %s\n" % repr(row)) # TODO debug
          if checkfor.strip() in row.strip(): return True
     return False

def checktags(mytags, symv, debug=False):
     '''
     check symv expression, see if it is true or false for this host
     mytags (requiRED): list
     symnv (requiRED): list
     debug (default False): bool
     '''
     symv_applies = False
     for tag in symv:
          if debug: print(tag),
          if tag in mytags:
               if not symv_applies: symv_applies = True
          elif tag[0] == "^" and not tag[1:] in mytags:
               if symv_applies: symv_applies = False
          elif tag[0] == "-" and tag[1:] in mytags:
               if symv_applies: symv_applies = False
          # mantle contains bang negation sometimes as well
          elif tag[0] == "!" and tag[1:] in mytags:
               if symv_applies: symv_applies = False
          if debug: print(' = %s' % symv_applies)
     if debug: print('\nmytags = %s\n' % mytags)
     return symv_applies

def checkpipe(pipe):
     try: return stat.S_ISFIFO(os.stat('/tmp/p.fifo').st_mode)
     except: return False

def checkcron(command, crontab):
     ''' looks through crontab, returns command if found '''
     for line in crontab.split('\n'):
          if command in line: return True, line
     return False, "command not found"

def checkfilename(file):
    return True if os.path.isfile(file) and os.path.getsize(file) > 0 else False

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# master check functions
def qc_processes(checklist):
     if VERB == "normal":
          print("\n     Processes:")
          print("     ----------\n")
     processes = pslist()
     passing_grade = True
     for check in checklist:
          #try: t = checklist[check]["type"]
          #except: pp(checklist[check])
          if OPTIONS.debug: print("\n{}:".format(check))
          if checklist[check]["type"] == 'process':
               passing_grade = True
               process = checklist[check]['process_name']
               # check process in pslist --------------------------------------
               ok = checkproc(process, processes)
               if not ok:
                    desc = "process ({}) not running".format(process)
                    FAILURES.append(desc)
                    passing_grade = False
               showresults(process, passing_grade)
     return passing_grade

def qc_databases(checklist):
     '''
     check type database entries in checklist
     note: environment down, /bb/bin/glm missing, lack of shaRED mem
     will NOT cause a failure here as it may be normal
     '''
     if VERB == "normal":
          print("\n     Databases:")
          print("     ----------\n")
     ok, glm = glmdblist()
     if not ok: # CRITICAL, don't continue checking
          showresults("/bb/biin/glm info not available (normal? BBENV down?) skipping db checks", 'na')
          return True
     showresults("glm information available", True)
     passing_grade = True
     for check in checklist:
          try: t = checklist[check]["type"]
          except: pp(checklist[check])
          if OPTIONS.debug: print("\n{}:".format(check))
          if checklist[check]["type"] == 'database':
               passing_grade = True
               db = checklist[check]['dbname']
               access = checklist[check]['rw']         # don't know if we can easily check this, skip for now
               cluster = checklist[check]['cluster']   # don't know if we can easily check this, skip for now
               if not db in glm:
                    desc = "database ({}) not showing in 'glm g' output".format(db)
                    FAILURES.append(desc)
                    passing_grade = False
               showresults(db, passing_grade)
     return passing_grade

def qc_mountpoints(checklist):
     ''' check type nfs entries in checklist '''
     if VERB == "normal":
          print("\n     Mounts:")
          print("     ----------\n")
     passing_grade = True
     for check in checklist:
          try: t = checklist[check]["type"]
          except: pp(checklist[check])
          if OPTIONS.debug: print("\n{}:".format(check))
          if checklist[check]["type"] == 'nfs':
               passing_grade = True
               if OPTIONS.debug:
                    #print("\n{}:".format(check))
                    pp(checklist[check])
               # get check information ----------------------------------------
               mountpoint = checklist[check]["export_name"]
               volume = checklist[check]["filer_volume"]
               filer = checklist[check]["filer_device"]
               mount_options = checklist[check]["mount_opts"] # currently UNUSED
               perms = checklist[check]["mount_acl"]
               # these are lists, as there may be more than one valid owner
               users = striplist(checklist[check]["mount_user"].split(','))
               groups = striplist(checklist[check]["mount_group"].split(','))
               # see if it's a mountpoint -------------------------------------
               ok = checkmount(mountpoint)
               if not ok: # not mounted is CRITICAL, don't continue checking
                    desc = "{} is NOT mounted".format(mountpoint)
                    FAILURES.append(desc)
                    showresults(mountpoint, passing_grade)
                    continue
               # check user ---------------------------------------------------
               ok, user = checkuser(mountpoint, users)
               if not ok:
                    desc = "{} owner ({}) should be ({})".format(
                         mountpoint, user, "|".join(users))
                    FAILURES.append(desc)
                    passing_grade = False
               # check group --------------------------------------------------
               ok, group = checkgroup(mountpoint, groups)
               if not ok:
                    desc = "{} group ({}) should be ({})".format(
                         mountpoint, group, "|".join(groups))
                    FAILURES.append(desc)
                    passing_grade = False
               # check filer and volume ---------------------------------------
               ok, actual_filer, actual_volume = checkfiler(mountpoint, filer, volume)
               if not ok:
                    desc = "{} filer setup ({}) should be ({})".format(
                         mountpoint, actual_filer + ":" + actual_volume, filer + ":" + volume)
                    FAILURES.append(desc)
                    passing_grade = False
               # check perms --------------------------------------------------
               ok, actual_perms = checkperms(mountpoint, perms)
               if not ok:
                    desc = "{} permissions ({}) should be ({})".format(
                         mountpoint, actual_perms, perms)
                    FAILURES.append(desc)
                    passing_grade = False
               showresults(mountpoint, passing_grade)
     return passing_grade

def qc_symlinks(checklist):
     ''' check type symlink entries in checklist '''
     if VERB == "normal":
          print("\n     Links:")
          print("     ----------\n")
     passing_grade = True
     for check in checklist:
          try: t = checklist[check]["type"]
          except: pp(checklist[check])
          if OPTIONS.debug: print("\n{}:".format(check))
          if checklist[check]["type"] == 'symlink':
               passing_grade = True
               link = checklist[check]['link_path']
               target = checklist[check]['target_path']
               # if we need variable expansion here ($HOST say) need to do something like
               # link = expandstring(link) where expandstring calls a subprocess with a shell
               # to expand the variable and returns the result
               # check link ---------------------------------------------------
               ok = os.path.islink(link)
               if not ok: # not a link is CRITICAL, don't continue checking
                    desc = "path {} is not a symlink but should be".format(link)
                    FAILURES.append(desc)
                    passing_grade = False
                    showresults(link, passing_grade)
                    continue
               # check target--------------------------------------------------
               actual_target = os.readlink(link)
               if not target == actual_target:
                    desc = "symlink {} points to ({}) should be ({})".format(
                         link, actual_target, target)
                    FAILURES.append(desc)
                    passing_grade = False
               showresults(link, passing_grade)
     return passing_grade

def qc_directories(checklist):
     ''' check type directory entries in checklist '''
     if VERB == "normal":
          print("\n     Directories:")
          print("     ----------------\n")
     passing_grade = True
     for check in checklist:
          try: t = checklist[check]["type"]
          except: pp(checklist[check])
          if OPTIONS.debug: print("\n{}:".format(check))
          if checklist[check]["type"] == 'directory':
               passing_grade = True
               path = checklist[check]['dir_path']
               perms = checklist[check]['dir_acl']
               # these are lists, as there may be more than one valid owner
               users = striplist(checklist[check]["dir_user"].split(','))
               groups = striplist(checklist[check]["dir_group"].split(','))
               # check dir ----------------------------------------------------
               if not os.path.isdir(path): # CRITICAL don't continue checking
                    desc = "{} is not a directory but should be".format(path)
                    FAILURES.append(desc)
                    passing_grade = False
                    showresults(path, passing_grade)
                    continue
               # check user ---------------------------------------------------
               ok, user = checkuser(path, users)
               if not ok:
                    desc = "{} owner ({}) should be ({})".format(
                         path, user, "|".join(users))
                    FAILURES.append(desc)
                    passing_grade = False
               # check group --------------------------------------------------
               ok, group = checkgroup(path, groups)
               if not ok:
                    desc = "{} group ({}) should be ({})".format(
                         path, group, "|".join(groups))
                    FAILURES.append(desc)
                    passing_grade = False
               # check perms --------------------------------------------------
               ok, actual_perms = checkperms(path, perms)
               if not ok:
                    desc = "{} permissions ({}) should be ({})".format(
                         path, actual_perms, perms)
                    FAILURES.append(desc)
                    passing_grade = False
               showresults(path, passing_grade)
     return passing_grade

def qc_files(checklist):
     ''' check that a filename is present '''
     if VERB == "normal":
          print("\n     Files:")
          print("     ----------\n")
     passing_grade = True
     for check in checklist:
          try: t = checklist[check]["type"]
          except: pp(checklist[check])
          if OPTIONS.debug: print("\n{}:".format(check))
          if checklist[check]["type"] == 'file':
               passing_grade = True
               pp(checklist[check])
               path = checklist[check]['file_path']
               ok = checkfilename(path)
               if not ok:
                    desc = "file ({}) does not exist, is 0bytes, or isn't a regular file"
                    FAILURES.append(desc)
                    passing_grade = False
               showresults(path, passing_grade)
     return passing_grade

def qc_cron(checklist):
     ''' check cron entries '''
     if VERB == "normal":
          print("\n     Cron entries:")
          print("     -----------------\n")
     passing_grade = True
     for check in checklist:
          try: t = checklist[check]["type"]
          except: pp(checklist[check])
          if OPTIONS.debug: print("\n{}:".format(check))
          if checklist[check]["type"] == 'cron':
               passing_grade = True
               schedule = checklist[check]['cron_schedule']
               user = checklist[check]['cron_user']
               command = checklist[check]['cron_command']
               if "linux" in mytags: cronlocation = "/var/spool/cron"
               else: cronlocation = "/var/spool/cron/crontabs"
               # get crontab --------------------------------------------------
               ok, crontab = sudo("cat {}/{}".format(cronlocation, user))
               if not ok: # CRITICAL don't continue checking
                    desc = "problem retrieving {}'s crontab ({})".format(user, crontab)
                    FAILURES.append(desc)
                    passing_grade = False
                    showresults(command, passing_grade)
                    continue
               # check for cronjob --------------------------------------------
               ok, cronjob = checkcron(command, crontab)
               if not ok: # CRITICAL don't continue checking
                    desc = "job ({}) not found in {}'s crontab".format(command, user)
                    FAILURES.append(desc)
                    passing_grade = False
                    showresults(command, passing_grade)
                    continue
               # check job schedule -------------------------------------------
               actual_schedule = " ".join(cronjob.split()[:5])
               if not schedule == actual_schedule:
                    desc = "wrong schedule ({}) for {}'s cronjob {} ({})".format(
                         actual_schedule, user, command, schedule)
                    FAILURES.append(desc)
                    passing_grade = False
               showresults(command, passing_grade)
     return passing_grade

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# =========  Main
# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
mytags = taglist()
if OPTIONS.debug: print('!! mytags: {}'.format(mytags))
if VERB == "normal":
     print("\n Healthcheck: %s (node %s) %s" % (mytags[0], mytags[1], mytags[2]))
     sep = "=" * (len(mytags[0]) + len(mytags[1]) + len(mytags[2]) + 22)
     print(" " + sep)
bbgh, mantle = bbgh_connect()
mantle_files = mantle.contents('etc/mantle.d', 'master').keys()

# -----------------------------------------------------------------------------
# read mantle files with names that match our tags from bbgithub
checks = {}
for filename in mantle_files:
     # for filenames that don't match a tag, there's always_include....
     always_include = ['general_mounts.mntl']
     if not filename in always_include:
          if not filename.endswith('.mntl'): continue
     if "-" in filename: filetag = filename.split('-')[0]
     elif "_" in filename: filetag = filename.split('_')[0]
     else: filetag = filename.split('.')[0]
     if checktags(mytags, [filetag]) or filename in always_include:
          # we care about these files, read them
          if OPTIONS.debug: print('++ filename: {}'.format(filename))
          contents = fetch_contents(mantle, filename)
          # sift through the file for symv expressions that match us
          stuff = parse_mantle_json(mytags,contents)
          #nest stuff in [checks] by filename as an intermediate step
          for key in stuff.keys():
               if not key.startswith('check:'):
                    checks['check:{}'.format(".".join(filename.split('.')[:-1]))] = stuff
                    break
          else:
               checks.update(stuff)
     elif OPTIONS.debug: print("-- filename: {}".format(filename))
checklist = flatten(checks, 0) # flatten structure, removing unecessary labels

# -----------------------------------------------------------------------------
# some output that may be helpful if debugging
#pp(checks)
#json.dump(checks, open('checks.json', 'w'), indent=4)
#json.dump(checklist, open('checklist.json', 'w'), indent=4)
#pp(checklist)
#print("\n".join(checklist.keys()))

# -----------------------------------------------------------------------------
# run check types vs this host
passing_grade = True
if not OPTIONS.nonfs:
     ok = qc_mountpoints(checklist)
     if not ok: passing_grade = False
if not OPTIONS.nolink:
     ok = qc_symlinks(checklist)
     if not ok: passing_grade = False
if not OPTIONS.nodir:
     ok = qc_directories(checklist)
     if not ok: passing_grade = False
if not OPTIONS.noproc:
     ok = qc_processes(checklist)
     if not ok: passing_grade = False
if not OPTIONS.nodb:
     ok = qc_databases(checklist)
     if not ok: passing_grade = False
if not OPTIONS.nocron:
     ok = qc_cron(checklist)
     if not ok: passing_grade = False
if not OPTIONS.nofile:
     ok = qc_files(checklist)
     if not ok: passing_grade = False

# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Fin
if passing_grade: toodles()
else: toodles(1)
