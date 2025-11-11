using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AuroraSyncDesk
{
    internal class ClientFile
    {
        public string originalPath { get; set; } = "";
        public string name { get; set; } = "";
        public long lastModified { get; set; }
    }
}
